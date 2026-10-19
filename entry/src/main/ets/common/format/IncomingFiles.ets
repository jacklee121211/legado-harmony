/**
 * 外部文件接收队列（2026-10-19 双响炮）。
 *
 * ── 为什么走 AppStorage 而不是在 EntryAbility 里直接导入 ──────────────────────
 * ① `onCreate` 阶段 DB 还没建表（`DbUtil.initDB` 在 `onWindowStageCreate`，见
 *    `EntryAbility.ets:171`）⇒ 在那里 `CopyFile` 写库必失败；
 * ② 工程已有约定：`captureQuickAction()` **只把意图写进 AppStorage，不在这里跳转**
 *    （`EntryAbility.ets:105-108`），由书架页消费。这里沿用同一条约定。
 *
 * 消费方：`BookContent.aboutToAppear`（DB 已就绪）+ `@StorageLink(INCOMING_TICK) @Watch`。
 */
export const INCOMING_TICK: string = 'FMT_INCOMING_TICK';
export const INCOMING_LIST: string = 'FMT_INCOMING_LIST';

export class IncomingFiles {
  /** 接收方（EntryAbility）调用：追加待导入 uri，并 +1 信号 */
  static push(uris: string[]): void {
    if (uris.length === 0) {
      return;
    }
    const prev: string[] = IncomingFiles.peek();
    const merged: string[] = [];
    for (const u of prev) {
      merged.push(u);
    }
    for (const u of uris) {
      if (u.length > 0 && merged.indexOf(u) < 0) {
        merged.push(u);
      }
    }
    AppStorage.setOrCreate(INCOMING_LIST, merged);
    const tick: number = (AppStorage.get<number>(INCOMING_TICK) ?? 0) + 1;
    AppStorage.setOrCreate(INCOMING_TICK, tick);
  }

  /** 只读当前队列（不清空） */
  static peek(): string[] {
    const raw: string[] | undefined = AppStorage.get<string[]>(INCOMING_LIST);
    return raw === undefined ? [] : raw;
  }

  /** 消费方调用：取出并清空 */
  static take(): string[] {
    const list: string[] = IncomingFiles.peek();
    AppStorage.setOrCreate(INCOMING_LIST, [] as string[]);
    return list;
  }
}
