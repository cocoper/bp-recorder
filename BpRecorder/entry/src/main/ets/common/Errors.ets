/**
 * 可携带业务错误码的异常类型。
 *
 * 为什么需要它：
 *   ArkTS 的 `arkts-limited-throw` 规则要求 `throw` 的值必须是 `Error` 或其**类**子类实例。
 *   而 SDK 的 `BusinessError` 在 `@ohos.base.d.ts` 中是 **interface**（`interface BusinessError<T = void> extends Error`），
 *   不是运行时类 —— 因此 `const e = err as BusinessError; throw e;` 会被判为「抛出任意类型」而编译失败
 *   （实测报错：10605087 "throw" statements cannot accept values of arbitrary types）。
 *
 * 用法：捕获 SDK 错误后，把 code / message 转成本类型再抛出。
 *       上层仍可按 `err as BusinessError` 读取 `.code` 与 `.message` ——
 *       BusinessError 的 `data` 为可选字段，因此本类型结构上兼容。
 */
export class AppError extends Error {
  /** 错误码，语义与 BusinessError.code 一致 */
  readonly code: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = 'AppError';
    this.code = code;
  }
}
