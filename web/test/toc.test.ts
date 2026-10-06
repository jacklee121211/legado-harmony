/**
 * toc 单测 —— 单源目录定位算法的守门人
 * 覆盖：顺序定位 / 行首要求 / 标题容错 / 书首目录块陷阱 / 三种放弃条件
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { locateToc, findAtLineStart } from '../src/toc.ts'

/** 造一本"标准"txt：每章 = 标题行 + 3 段正文，段落之间空行 */
function makeBook(chapters: number, parasPerChapter = 3): { text: string; titles: string[] } {
  const lines: string[] = []
  const titles: string[] = []
  for (let c = 1; c <= chapters; c++) {
    const t = `第${c}章 标题${c}`
    titles.push(t)
    lines.push(t, '')
    for (let p = 1; p <= parasPerChapter; p++) {
      lines.push(`这是第${c}章第${p}段。` + '正文内容重复填充以拉长章节跨度。'.repeat(4), '')
    }
  }
  return { text: lines.join('\n'), titles }
}

test('标准书：逐章定位，区间单调且覆盖全篇', () => {
  const { text, titles } = makeBook(30)
  const toc = locateToc(text, titles)
  assert.equal(toc.length, 30)
  assert.equal(toc[0]!.title, '第1章 标题1')
  assert.equal(toc[0]!.charStart, 0)
  assert.equal(toc[29]!.charEnd, text.length)
  for (let i = 1; i < toc.length; i++) {
    assert.equal(toc[i]!.charStart, toc[i - 1]!.charEnd)
    assert.ok(toc[i]!.charStart > toc[i - 1]!.charStart)
  }
  // 每个 charStart 处真的就是该标题
  for (const e of toc) assert.ok(text.startsWith(e.title, e.charStart))
})

/** 填充一段足够长的正文（守卫要求平均章长 ≥120 字符，真实书都远超） */
function body(c: number, n = 6): string {
  return (`第${c}章正文段落。` + '内容重复填充，用来把章节跨度拉到真实量级。'.repeat(3)) + '\n\n' + 'x'.repeat(n * 30)
}

test('顺序定位：同名标题不会全挤到第一处', () => {
  const text = [
    '第一章 甲', '', body(1), '',
    '第一章 甲', '', body(2), '',
    '第一章 甲', '', body(3)
  ].join('\n')
  const toc = locateToc(text, ['第一章 甲', '第一章 甲', '第一章 甲'])
  assert.equal(toc.length, 3)
  assert.notEqual(toc[0]!.charStart, toc[1]!.charStart)
  assert.notEqual(toc[1]!.charStart, toc[2]!.charStart)
})

test('行首要求：正文中间提到的标题不被当章节', () => {
  const text = [
    '第一章 真章', '', body(1), '',
    '这一句里提到第一章 真章 几个字', '',
    '第二章 真章2', '', body(2), '',
    '第三章 真章3', '', body(3)
  ].join('\n')
  const toc = locateToc(text, ['第一章 真章', '第二章 真章2', '第三章 真章3'])
  assert.equal(toc.length, 3)
  assert.equal(toc[1]!.charStart, text.indexOf('\n第二章 真章2') + 1)
})

test('findAtLineStart：只在行首命中', () => {
  const t = 'xxxABC\nABC\nyyyABC'
  assert.equal(findAtLineStart(t, 'ABC', 0), 7)   // 3 处不是行首，7 处是
  assert.equal(findAtLineStart(t, 'ABC', 8), -1)  // 从 8 起只剩非行首的
  assert.equal(findAtLineStart('\nABC', 'ABC', 0), 1)
  assert.equal(findAtLineStart('ABC', 'ABC', 0), 0)
})

test('标题容错：标题被截断时退化用前 8 字', () => {
  const text = [
    '第一章 很长很长的标题A', '', body(1), '',
    '第二章 很长很长的标题B', '', body(2), '',
    '第三章 很长很长的标题C', '', body(3)
  ].join('\n')
  const toc = locateToc(text, ['第一章 很长很长', '第二章 很长很长', '第三章 很长很长'])
  assert.equal(toc.length, 3)
  assert.equal(toc[0]!.charStart, 0)
})

test('书首目录块陷阱：跳过开头的目录块，落到真实章节', () => {
  const body: string[] = []
  const titles: string[] = []
  for (let c = 1; c <= 20; c++) {
    const t = `第${c}章 标题${c}`
    titles.push(t)
    body.push(t, '', `第${c}章正文。` + '内容'.repeat(120), '')
  }
  // 书首先来一份"目录"：每行一个标题（同样在行首 ⇒ 会被误命中）
  const tocBlock = titles.join('\n')
  const text = tocBlock + '\n\n' + body.join('\n')
  const toc = locateToc(text, titles)
  assert.equal(toc.length, 20)
  // 关键：第一处命中的是**正文里的**标题，而不是书首目录块里的
  assert.ok(toc[0]!.charStart >= tocBlock.length, '第一章应当落在目录块之后')
  assert.ok(text.startsWith(titles[0]!, toc[0]!.charStart))
})

test('放弃条件：命中率过低 / 条数太少 / 平均跨度过小 ⇒ 返回空数组（调用方回退）', () => {
  const { text } = makeBook(10)
  // ① 标题完全对不上
  assert.deepEqual(locateToc(text, ['完全不相干甲', '完全不相干乙', '完全不相干丙', '完全不相干丁']), [])
  // ② 条数 < 3
  assert.deepEqual(locateToc(text, ['第1章 标题1']), [])
  // ③ 标题都挤在正文开头极短一段内（平均跨度远小于下限）
  const crowded = '第一章 A\n第二章 B\n第三章 C\n第四章 D\n'
  assert.deepEqual(locateToc(crowded, ['第一章 A', '第二章 B', '第三章 C', '第四章 D']), [])
  // ④ 空标题列表
  assert.deepEqual(locateToc(text, []), [])
})
