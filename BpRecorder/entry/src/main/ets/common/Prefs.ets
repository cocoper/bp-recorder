import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrefKeys, RefBasis } from './Constants';
import { GradeStandard, parseGradeStandard } from '../model/Types';
import { Logger } from './Logger';

const TAG: string = 'Prefs';

/**
 * 用户偏好读写（不建表，策划文档 §3.1）。
 * 统一收敛在此，避免各页面各自处理 Preferences 的异常与默认值。
 */
export class Prefs {
  private static store(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: PrefKeys.STORE });
  }

  /**
   * 参考口径（FR-7.1，v1.3 由「分级标准」更名），默认家庭自测口径。
   * 默认取 RefBasis.DEFAULT：本 App 数据 100% 为居家自测（§1.2），
   * 默认口径与数据场景一致，避免开箱即用诊室阈值去判家庭数据（决策 D1）。
   */
  static standard(context: common.Context): GradeStandard {
    try {
      const raw: string = Prefs.store(context).getSync(PrefKeys.GRADE_STANDARD, '') as string;
      if (raw === null || raw === undefined || raw.length === 0) {
        return RefBasis.DEFAULT;
      }
      return parseGradeStandard(raw);
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `read grade standard failed: ${e.message}`);
      return RefBasis.DEFAULT;
    }
  }

  static setStandard(context: common.Context, standard: GradeStandard): void {
    try {
      const store: preferences.Preferences = Prefs.store(context);
      store.putSync(PrefKeys.GRADE_STANDARD, `${standard}`);
      store.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `write grade standard failed: ${e.message}`);
    }
  }

  /** 首启免责声明是否已展示（CL-6：仅一次） */
  static isDisclaimerShown(context: common.Context): boolean {
    try {
      return Prefs.store(context).getSync(PrefKeys.DISCLAIMER_SHOWN, false) as boolean;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `read disclaimer flag failed: ${e.message}`);
      return false;
    }
  }

  static markDisclaimerShown(context: common.Context): void {
    try {
      const store: preferences.Preferences = Prefs.store(context);
      store.putSync(PrefKeys.DISCLAIMER_SHOWN, true);
      store.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `write disclaimer flag failed: ${e.message}`);
    }
  }

  /** 清空数据后重置首启标记（让用户重新看到免责声明），保留分级标准 */
  static resetDisclaimer(context: common.Context): void {
    try {
      const store: preferences.Preferences = Prefs.store(context);
      store.putSync(PrefKeys.DISCLAIMER_SHOWN, false);
      store.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `reset disclaimer flag failed: ${e.message}`);
    }
  }

  /**
   * 是否已经为用户主动请求过一次通知授权（v1.14）。
   *
   * 背景：`publishReminder` 要求已获通知授权，否则返回 `1700001`。此前只有设置页
   * 那一行会请求授权，于是「从没进过设置页」的用户永远收不到服药提醒 —— 且没有任何提示。
   * 现在启动时有生效计划就会请求一次；这个标记保证**每次安装至多弹一次**系统授权框，
   * 用户拒绝后不再骚扰，而是改由用药页的警示卡与设置页的「已登记提醒」继续如实告知。
   */
  static isNotifyAsked(context: common.Context): boolean {
    try {
      return Prefs.store(context).getSync(PrefKeys.NOTIFY_ASKED, false) as boolean;
    } catch (err) {
      const e = err as BusinessError;
      Logger.warn(TAG, `read notify-asked flag failed: ${e.message}`);
      return true;
    }
  }

  static markNotifyAsked(context: common.Context): void {
    try {
      const store: preferences.Preferences = Prefs.store(context);
      store.putSync(PrefKeys.NOTIFY_ASKED, true);
      store.flush();
    } catch (err) {
      const e = err as BusinessError;
      Logger.error(TAG, `write notify-asked flag failed: ${e.message}`);
    }
  }
}
