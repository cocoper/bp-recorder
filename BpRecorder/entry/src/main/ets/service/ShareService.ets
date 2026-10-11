import { common } from '@kit.AbilityKit';
import { componentSnapshot } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo } from '@kit.CoreFileKit';
import { systemShare } from '@kit.ShareKit';
import { print } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';
import { FileService } from './FileService';
import { ShareConst } from '../common/Constants';

const TAG: string = 'ShareService';

/**
 * 出图、分享、存相册、打印（FR-10.3 / FR-11）。
 *
 * 技术路径（经裁决采用「纯 ArkUI 同源」）：
 *   报告与图表均以 ArkUI 组件离屏渲染 → componentSnapshot 出 PixelMap
 *   → 打包为 PNG → 同一份 PNG 支持「存相册 / 系统分享 / 打印」三条输出，
 *   三路共用同一渲染源，避免多套排版导致的数值与版式漂移。
 *
 * 权限：SaveButton 为系统安全控件，保存相册无需申请相册权限（NFR-5）。
 */
export class ShareService {
  /**
   * 把指定 id 的组件渲染为 PixelMap。
   * 要求组件在页面上真实存在（报告页使用离屏容器，宽度按 1080 目标换算）。
   */
  static async snapshot(componentId: string): Promise<image.PixelMap> {
    return componentSnapshot.get(componentId);
  }

  /** 出图目标宽度（像素）：显式契约，不随屏幕密度/用户缩放变化（审查 R15.3） */
  static readonly CAPTURE_WIDTH_PX: number = ShareConst.CAPTURE_WIDTH_PX;
  /** 单张位图的最大像素高：超过就必须分页/多图，不能缩到不可读（审查 R15.4） */
  static readonly CAPTURE_MAX_HEIGHT_PX: number = ShareConst.CAPTURE_MAX_HEIGHT_PX;

  /** 目标像素宽 → 离屏容器 vp 宽（vp = px / density） */
  static captureWidthVp(density: number): number {
    const d: number = density > 0 ? density : 1;
    return ShareService.CAPTURE_WIDTH_PX / d;
  }

  /**
   * 出图预算（审查 R15.4）：按预估高度判断单张还是需要分页，并给出可提示的编号信息。
   * 纯函数，便于离线回归；真正分页输出仍由页面按计划逐张渲染。
   */
  static planCapture(estimatedHeightVp: number, density: number): CapturePlan {
    const d: number = density > 0 ? density : 1;
    const heightVp: number = estimatedHeightVp > 0 ? estimatedHeightVp : 0;
    const heightPx: number = Math.ceil(heightVp * d);
    const pages: number = heightPx <= ShareService.CAPTURE_MAX_HEIGHT_PX
      ? 1 : Math.ceil(heightPx / ShareService.CAPTURE_MAX_HEIGHT_PX);
    return {
      widthPx: ShareService.CAPTURE_WIDTH_PX,
      heightPx: heightPx,
      pages: pages,
      split: pages > 1
    };
  }

  /**
   * 快照 → 消费 → **必定释放**（审查 R15.1）。
   * PixelMap 是原生内存，创建者必须在消费全部结束后释放；过去调用点拿到 PixelMap 后没有 release。
   */
  static async withSnapshot<T>(componentId: string,
    work: (pixelMap: image.PixelMap) => Promise<T>): Promise<T> {
    const pixelMap: image.PixelMap = await ShareService.snapshot(componentId);
    try {
      return await work(pixelMap);
    } finally {
      try {
        pixelMap.release();
      } catch (err) {
        const e = err as BusinessError;
        Logger.warn(TAG, `pixelMap release failed: code=${e.code}, message=${e.message}`);
      }
    }
  }

  /** PixelMap → PNG 字节（无损，保证微信查看清晰，FR-11.4） */
  static async packPng(pixelMap: image.PixelMap): Promise<ArrayBuffer> {
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      const options: image.PackingOption = { format: 'image/png', quality: 100 };
      return await packer.packToData(pixelMap, options);
    } finally {
      packer.release();
    }
  }

  /**
   * 保存 PNG 到相册。
   * 必须由安全控件 SaveButton 的 onClick 回调触发（此时系统已授权本次写入）。
   */
  static async saveToAlbum(context: common.UIAbilityContext, data: ArrayBuffer): Promise<void> {
    const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
    let assetUri: string = '';
    try {
      assetUri = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
      const file: fileIo.File = await fileIo.open(assetUri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      try {
        await fileIo.write(file.fd, data);
      } finally {
        await fileIo.close(file);
      }
      Logger.info(TAG, 'image saved to album');
    } catch (err) {
      // 审查 R15.1：中途失败必须把已经创建的相册资产删掉，不能只关 fd 留一张半张图
      if (assetUri.length > 0) {
        try {
          await photoAccessHelper.MediaAssetChangeRequest.deleteAssets(context, [assetUri]);
          Logger.warn(TAG, 'half-written album asset deleted');
        } catch (cleanErr) {
          const ce = cleanErr as BusinessError;
          Logger.error(TAG, `delete half-written asset failed: code=${ce.code}, message=${ce.message}`);
        }
      }
      const e = err as BusinessError;
      const failure: Error = err instanceof Error ? err : new Error(`saveToAlbum failed: code=${e.code}`);
      throw failure;
    }
  }

  /** 生成图片 → 调起系统分享面板 */
  static async shareImage(context: common.UIAbilityContext, pixelMap: image.PixelMap,
    fileName: string, title: string): Promise<void> {
    const data: ArrayBuffer = await ShareService.packPng(pixelMap);
    const uri: string = await FileService.writeTempImage(context, fileName, data);
    const shareData: systemShare.SharedData = new systemShare.SharedData({
      utd: utd.UniformDataType.PNG,
      uri: uri,
      title: title
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DETAIL
    });
    Logger.info(TAG, 'share panel opened');
  }

  /** 调起系统打印界面（用户可「另存为 PDF」，FR-10.3） */
  static async printImage(context: common.UIAbilityContext, pixelMap: image.PixelMap,
    fileName: string): Promise<void> {
    const data: ArrayBuffer = await ShareService.packPng(pixelMap);
    const uri: string = await FileService.writeTempImage(context, fileName, data);
    await print.print([uri]);
    Logger.info(TAG, 'print dialog opened');
  }

  /** 出图失败时的错误描述（页面据此提示用户） */
  static describeError(err: BusinessError): string {
    return `code=${err.code}, message=${err.message}`;
  }
}

/** 出图预算：单张像素尺寸与页数（审查 R15.4） */
export interface CapturePlan {
  widthPx: number;
  heightPx: number;
  /** 需要输出几张（1 = 单张） */
  pages: number;
  /** 是否需要分页输出 */
  split: boolean;
}
