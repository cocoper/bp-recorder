import { FormExtensionAbility, formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { Want, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { BpDatabase } from '../service/BpDatabase';
import { MedLog } from '../model/Med';
import { TodayCardBinding, TodayCardBuilder, TodayCardData } from '../service/TodayCardBuilder';
import { DateUtils } from '../common/DateUtils';
import { PrefKeys } from '../common/Constants';
import { Logger } from '../common/Logger';

const TAG: string = 'EntryFormAbility';

/** 已添加卡片的登记项（尺寸决定是否展示分次明细） */
interface FormEntry {
  id: string;
  big: boolean;
}

/**
 * 桌面卡片「今日用药」的 FormExtensionAbility。
 *
 * 数据路径：卡片进程自己初始化数据库（与 App 共用同一个应用沙箱内的 RDB）→ 查今天的打卡记录
 * → TodayCardBuilder 纯函数算出展示字段 → 通过 formBindingData 推给卡片 UI。
 * 卡片只读，不改任何业务数据；写操作仍全部走 App 内的领域命令。
 */
export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string = EntryFormAbility.formIdOf(want);
    const big: boolean = EntryFormAbility.isBig(want);
    Logger.info(TAG, `onAddForm formId=${formId} big=${big}`);
    this.trackFormId(formId, true, big);
    this.refresh(formId);
    // 先返回占位内容，真实数据由 refresh 异步推送（避免卡片系统等待超时）
    const placeholder: TodayCardBinding = {
      hasPlan: 0, total: 0, taken: 0, pending: 0, missed: 0,
      headline: '读取中', subline: '正在读取今日用药…', tone: 'idle',
      nextTime: '', rowsText: '', rowCount: 0, updatedAt: '', showRows: big ? 1 : 0,
      dateLabel: '', rowsJson: '[]'
    };
    return formBindingData.createFormBindingData(placeholder);
  }

  onUpdateForm(formId: string): void {
    Logger.info(TAG, `onUpdateForm formId=${formId}`);
    this.refresh(formId);
  }

  onRemoveForm(formId: string): void {
    Logger.info(TAG, `onRemoveForm formId=${formId}`);
    this.trackFormId(formId, false, false);
  }

  onFormEvent(formId: string, message: string): void {
    Logger.info(TAG, `onFormEvent formId=${formId} message=${message}`);
    this.refresh(formId);
  }

  /** 卡片尺寸是否为「大卡」：只有大卡才展示分次明细（2*2 放不下） */
  private static isBig(want: Want): boolean {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return false;
    }
    // formInfo.FormParam.DIMENSION_KEY 的值是 FormDimension **数值枚举**（1=1*2、2=2*2、4=4*4…），
    // 不是 "2*2" 字符串 —— 之前按字符串比较，导致 2*2 也被当成大卡、把明细挤进了小卡。
    const raw: Object | undefined = params[formInfo.FormParam.DIMENSION_KEY];
    if (raw === undefined || raw === null) {
      return false;
    }
    const dim: number = Number(raw);
    if (Number.isNaN(dim)) {
      return false;
    }
    // 本卡片声明 2*2 与 2*4：2*4（竖长条）才展示分次明细，2*2 保持克制
    return dim === formInfo.FormDimension.Dimension_2_4;
  }

  /** 从 want 里取卡片实例 id（不同 API 版本字段位置一致，取不到则用空串兜底） */
  private static formIdOf(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return '';
    }
    const raw: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
    return raw === undefined || raw === null ? '' : String(raw);
  }

  /** 绑定字段：在基础字段上补 showRows（大卡才展示分次明细） */
  static bindingOf(data: TodayCardData, big: boolean): TodayCardBinding {
    const base: TodayCardBinding = TodayCardBuilder.toBinding(data);
    base.showRows = big ? 1 : 0;
    return base;
  }

  /** 容错解析：兼容早期只存 id 字符串的形态 */
  static parseForms(raw: string): FormEntry[] {
    const out: FormEntry[] = [];
    try {
      const arr = JSON.parse(raw) as Array<Object>;
      for (let i = 0; i < arr.length; i++) {
        const item = arr[i];
        if (typeof item === 'string') {
          out.push({ id: item as string, big: false });
        } else {
          const obj = item as Record<string, Object>;
          const id: string = obj['id'] === undefined ? '' : String(obj['id']);
          const big: boolean = obj['big'] === undefined ? false : (obj['big'] as boolean);
          if (id.length > 0) {
            out.push({ id: id, big: big });
          }
        }
      }
    } catch (err) {
      return out;
    }
    return out;
  }

  /** 查这张卡片是否大卡 */
  private isBigForm(formId: string): boolean {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(this.context,
        { name: PrefKeys.STORE });
      const raw: string = store.getSync(PrefKeys.FORM_IDS, '[]') as string;
      const ids: FormEntry[] = EntryFormAbility.parseForms(raw);
      for (let i = 0; i < ids.length; i++) {
        if (ids[i].id === formId) {
          return ids[i].big;
        }
      }
    } catch (err) {
      return false;
    }
    return false;
  }

  /** 记录「当前有哪些卡片实例」：App 内打卡后据此定向推送刷新 */
  private trackFormId(formId: string, add: boolean, big: boolean): void {
    if (formId.length === 0) {
      return;
    }
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(this.context,
        { name: PrefKeys.STORE });
      const raw: string = store.getSync(PrefKeys.FORM_IDS, '[]') as string;
      const ids: FormEntry[] = EntryFormAbility.parseForms(raw);
      const next: FormEntry[] = [];
      for (let i = 0; i < ids.length; i++) {
        if (ids[i].id !== formId) {
          next.push(ids[i]);
        }
      }
      if (add) {
        next.push({ id: formId, big: big });
      }
      store.putSync(PrefKeys.FORM_IDS, JSON.stringify(next));
      store.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `track form id failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 读库 → 构建 → 推送（失败只记日志，不影响卡片存活） */
  private async refresh(formId: string): Promise<void> {
    if (formId.length === 0) {
      return;
    }
    const big: boolean = this.isBigForm(formId);
    try {
      const db: BpDatabase = BpDatabase.getInstance();
      await db.init(this.context as common.Context);
      const now: number = DateUtils.now();
      const logs: MedLog[] = await db.queryMedLogsOfDay(now);
      const data: TodayCardData = TodayCardBuilder.build(logs, now);
      const binding: formBindingData.FormBindingData =
        formBindingData.createFormBindingData(EntryFormAbility.bindingOf(data, big));
      await formProvider.updateForm(formId, binding);
      Logger.info(TAG, `card refreshed: tone=${data.tone}, ${data.taken}/${data.total}`);
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `refresh card failed: code=${e.code}, message=${e.message}`);
    }
  }
}
