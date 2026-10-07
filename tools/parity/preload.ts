// 编译期桩：为离线编译产物注入运行时实现。
// 仅用于本机校验，不进入真实工程构建。
(globalThis as unknown as Record<string, unknown>)['$r'] = (key: string): { id: number } => ({ id: 0 });
export {};
