/**
 * model 单测 —— 「字符偏移是唯一坐标」这条不变量的守门人
 * 关键不变量：对任意段落，raw.slice(charStart, charEnd) === text（偏移必须真的指回原文）
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  splitParagraphs, splitChaptersByRegex, chaptersFromToc, paragraphAt,
  chapterIndexOfPara, posRatioInChapter, chapterRatio, findChapterByTitle,
  numOfChapterTitle, cnToNum
} from '../src/model.ts'

const RAW = [
  '第一章 起点',
  '',
  '甲甲甲',
  '',
  '  乙乙  ',
  '',
  '',
  '第二章 中途',
  '',
  '丙丙丙丙',
  '',
  '后记',
  '',
  '丁丁'
].join('\n')

test('splitParagraphs：偏移指回原文（核心不变量）+ 空段被丢弃 + 首尾空白被 trim', () => {
  const paras = splitParagraphs(RAW)
  assert.equal(paras.length, 7)
  for (const p of paras) {
    assert.equal(RAW.slice(p.charStart, p.charEnd), p.text, `偏移失配: ${JSON.stringify(p.text)}`)
    assert.ok(p.text.trim() === p.text)
    assert.ok(p.text.length > 0)
  }
  assert.equal(paras[0]!.text, '第一章 起点')
  assert.equal(paras[2]!.text, '乙乙')
  // 段落偏移必须单调递增且不重叠
  for (let i = 1; i < paras.length; i++) {
    assert.ok(paras[i]!.charStart >= paras[i - 1]!.charEnd)
  }
})

test('paragraphAt：二分查找（含边界与越界）', () => {
  const paras = splitParagraphs(RAW)
  assert.equal(paragraphAt(paras, -100), 0)
  assert.equal(paragraphAt(paras, paras[0]!.charStart), 0)
  assert.equal(paragraphAt(paras, paras[3]!.charStart), 3)
  assert.equal(paragraphAt(paras, paras[3]!.charStart - 1), 2)
  assert.equal(paragraphAt(paras, 10 ** 9), paras.length - 1)
})

test('splitChaptersByRegex：识别"第X章"，并把"后记"也算一章（与旧实现同款）', () => {
  const paras = splitParagraphs(RAW)
  const chs = splitChaptersByRegex(paras)
  assert.equal(chs.length, 3)
  assert.equal(chs[0]!.title, '第一章 起点')
  assert.equal(chs[1]!.title, '第二章 中途')
  assert.equal(chs[2]!.title, '后记')
  assert.equal(chs[0]!.paraFrom, 0)
  assert.equal(chs[1]!.paraFrom, 3)
  assert.equal(chs[2]!.paraTo, paras.length)
  assert.equal(chs[0]!.charStart, paras[0]!.charStart)
  assert.equal(chs[2]!.charEnd, paras[paras.length - 1]!.charEnd)
})

test('chaptersFromToc：把手机端下发的字符区间吸附到段落边界', () => {
  const paras = splitParagraphs(RAW)
  const toc = [
    { title: '章一', charStart: 0, charEnd: paras[2]!.charEnd },
    { title: '章二', charStart: paras[3]!.charStart, charEnd: paras[6]!.charEnd }
  ]
  const chs = chaptersFromToc(paras, toc)
  assert.ok(chs)
  assert.equal(chs!.length, 2)
  assert.equal(chs![0]!.paraFrom, 0)
  assert.equal(chs![0]!.paraTo, 3)
  assert.equal(chs![1]!.paraFrom, 3)
  assert.equal(chs![1]!.paraTo, 7)
  assert.equal(chs![0]!.from, 'toc')
  // 空目录 ⇒ null（调用方回退到正则切分）
  assert.equal(chaptersFromToc(paras, []), null)
})

test('chapterIndexOfPara / posRatioInChapter / chapterRatio', () => {
  const paras = splitParagraphs(RAW)
  const chs = splitChaptersByRegex(paras)
  assert.equal(chapterIndexOfPara(chs, 0), 0)
  assert.equal(chapterIndexOfPara(chs, 2), 0)
  assert.equal(chapterIndexOfPara(chs, 3), 1)
  assert.equal(chapterIndexOfPara(chs, 6), 2)
  assert.equal(posRatioInChapter(chs, 3), 0)
  // 注意：`后记` 也命中章节正则 ⇒ 第二章的段落区间是 [3,5)（第二章 + 丙丙丙丙）
  // ⇒ 段 4 在第二章里的比例 = (4-3)/(5-3) = 0.5
  assert.equal(chs[1]!.paraTo, 5)
  assert.equal(posRatioInChapter(chs, 4), 0.5)
  assert.equal(chapterRatio(chs, 0), 0)
  assert.equal(chapterRatio(chs, 2), 1)
})

test('numOfChapterTitle / cnToNum：阿拉伯与中文数字都要认', () => {
  assert.equal(numOfChapterTitle('第12章 风起'), 12)
  assert.equal(numOfChapterTitle('第十二章 风起'), 12)
  assert.equal(numOfChapterTitle('第二十章'), 20)
  assert.equal(numOfChapterTitle('第 3 节'), 3)
  assert.equal(numOfChapterTitle('序章'), -1)
  assert.equal(cnToNum('十'), 10)
  assert.equal(cnToNum('十二'), 12)
  assert.equal(cnToNum('二十'), 20)
  assert.equal(cnToNum('一百零三'), 103)
  assert.equal(cnToNum('两'), 2)
  assert.equal(cnToNum('甲'), -1)
})

test('findChapterByTitle：数字优先，前 8 字互含兜底，找不到返回 -1', () => {
  const paras = splitParagraphs(RAW)
  const chs = splitChaptersByRegex(paras)
  assert.equal(findChapterByTitle(chs, '第2章 随便什么名字'), 1)
  assert.equal(findChapterByTitle(chs, '第一章 起点'), 0)
  assert.equal(findChapterByTitle(chs, '后记'), 2)
  assert.equal(findChapterByTitle(chs, '完全不相干的标题'), -1)
  assert.equal(findChapterByTitle(chs, ''), -1)
})
