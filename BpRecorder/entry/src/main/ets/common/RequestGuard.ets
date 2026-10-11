/**
 * 异步请求序号守卫（审查 R12）。
 *
 * 页面每次发起查询/构建都取一个递增 token，只有「最后发出的那次」允许提交视图状态；
 * 过期响应直接丢弃，页面销毁后（dispose）任何在途响应都不得再改动视图。
 * 这样就不会出现「先点的 7 天比后点的 90 天晚回来，把 90 天的标签配 7 天的数据」。
 */
export class RequestGuard {
  private seq: number = 0;
  private disposed: boolean = false;

  /** 取一个新 token；页面已销毁时返回 -1，调用方应立即返回 */
  next(): number {
    if (this.disposed) {
      return -1;
    }
    this.seq++;
    return this.seq;
  }

  /** 该 token 是否仍是当前有效请求 */
  isCurrent(token: number): boolean {
    return !this.disposed && token === this.seq;
  }

  /** 页面销毁：作废所有在途请求 */
  dispose(): void {
    this.disposed = true;
    this.seq++;
  }

  /** 是否已销毁（供 finally 判断要不要复位 busy 之类的视图状态） */
  isDisposed(): boolean {
    return this.disposed;
  }
}
