import { formBindingData, formProvider } from '@kit.FormKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BpDatabase } from './BpDatabase';
import { MedLog } from '../model/Med';
import { TodayCardBinding, TodayCardBuilder, TodayCardData } from './TodayCardBuilder';
import { DateUtils } from '../common/DateUtils';
import { PrefKeys } from '../common/Constants';
import { Logger } from '../common/Logger';

const TAG: string = 'TodayCardService';

/** 已添加卡片的登记项（与 EntryFormAbility 的存储格式一致） */
interface FormEntry {
  id: string;
  big: boolean;
}

/**
 * App 侧把「今日用药」变化推给已添加的桌面卡片。
 *
 * 卡片进程与 App 进程是分开的：这里不直接读库算一次再推，而是**通知每张卡片自己去刷新**
 * （push 一次 binding 也要带上数据，所以这里同样读库构建一份，保证两进程口径一致）。
 * 任何失败只记日志：卡片刷新失败不该影响打卡/保存等主流程。
 */
export class TodayCardService {
  /** 绑定字段：基础字段 + showRows */
  static bindingOf(data: TodayCardData, big: boolean): TodayCardBinding {
    const base: TodayCardBinding = TodayCardBuilder.toBinding(data);
    base.showRows = big ? 1 : 0;
    return base;
  }

  /** 容错解析登记表（兼容早期只存 id 的形态） */
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

  static async refreshAll(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: PrefKeys.STORE });
      const raw: string = store.getSync(PrefKeys.FORM_IDS, '[]') as string;
      const ids: FormEntry[] = TodayCardService.parseForms(raw);
      if (ids.length === 0) {
        return;
      }
      const db: BpDatabase = BpDatabase.getInstance();
      const now: number = DateUtils.now();
      const logs: MedLog[] = await db.queryMedLogsOfDay(now);
      const data: TodayCardData = TodayCardBuilder.build(logs, now);
      for (let i = 0; i < ids.length; i++) {
        const binding: formBindingData.FormBindingData =
          formBindingData.createFormBindingData(TodayCardService.bindingOf(data, ids[i].big));
        try {
          await formProvider.updateForm(ids[i].id, binding);
        } catch (err) {
          const e = err as BusinessError;
          Logger.warn(TAG, `update form ${ids[i].id} failed: code=${e.code}, message=${e.message}`);
        }
      }
      Logger.info(TAG, `pushed today card to ${ids.length} form(s)`);
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `refresh today card failed: code=${e.code}, message=${e.message}`);
    }
  }
}
