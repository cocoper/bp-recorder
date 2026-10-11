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
    const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
    const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
    try {
      await fileIo.write(file.fd, data);
    } finally {
      await fileIo.close(file);
    }
    Logger.info(TAG, 'image saved to album');
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
