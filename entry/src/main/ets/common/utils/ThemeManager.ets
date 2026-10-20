import { ThemeColor, ThemeStorageKey } from "../constants/Theme";
import { ThemeItem } from "../model/Theme";

export class ThemeManager {
  themeList: ThemeItem[] = [
    {text: '主题1', mainColor: ThemeColor.ORANGE.mainColor, secondColor: ThemeColor.ORANGE.secondColor},
    {text: '主题2', mainColor: ThemeColor.RED.mainColor, secondColor: ThemeColor.RED.secondColor},
    {text: '主题3', mainColor: ThemeColor.GREEN.mainColor, secondColor: ThemeColor.GREEN.secondColor},
    {text: '主题4', mainColor: ThemeColor.YELLOW.mainColor, secondColor: ThemeColor.YELLOW.secondColor},
    {text: '主题5', mainColor: ThemeColor.BLUE.mainColor, secondColor: ThemeColor.BLUE.secondColor},
  ]

  init() {
    // ⚠️ 2026-10-21：曾加过一段"内置主题配色版本迁移"（刷新已装机器的旧配色），
    //   后按用户口径**删除** —— 项目尚未上架，没有老用户数据要兼容。
    //   改 `ThemeColor` 常量即可，重装/清数据后生效。
    PersistentStorage.persistProp<ThemeItem>(ThemeStorageKey.THEME, {text: '主题1', mainColor: ThemeColor.ORANGE.mainColor, secondColor: ThemeColor.ORANGE.secondColor})
    PersistentStorage.persistProp<string>(ThemeStorageKey.THEMELISTSTR, JSON.stringify(this.themeList))

    // 解析主题数组字符串 加载主题
    const str = AppStorage.get<string>(ThemeStorageKey.THEMELISTSTR)
    const themeList = JSON.parse(str as string) as ThemeItem[]
    AppStorage.setOrCreate<ThemeItem[]>(ThemeStorageKey.THEMELIST, themeList)

    PersistentStorage.persistProp<number>(ThemeStorageKey.THEMEINDEX, 0) // 被选中主题的索引
  }

  setTheme(newTheme: ThemeItem, index: number) {
    AppStorage.setOrCreate<ThemeItem>(ThemeStorageKey.THEME, newTheme)
    AppStorage.setOrCreate<number>(ThemeStorageKey.THEMEINDEX, index)
  }

  addTheme(newTheme: ThemeItem) {
    const str = AppStorage.get<string>(ThemeStorageKey.THEMELISTSTR)
    const themeList = JSON.parse(str as string) as ThemeItem[]
    themeList.push(newTheme)
    AppStorage.setOrCreate(ThemeStorageKey.THEMELISTSTR, JSON.stringify(themeList))
    AppStorage.setOrCreate<ThemeItem[]>(ThemeStorageKey.THEMELIST, themeList)
  }

  deleteTheme(index: number) {
    const str = AppStorage.get<string>(ThemeStorageKey.THEMELISTSTR)
    let themeList = JSON.parse(str as string) as ThemeItem[]
    let activeIndex: number = AppStorage.get<number>(ThemeStorageKey.THEMEINDEX) as number
    if (activeIndex > index) {
        --activeIndex
    } else if (activeIndex == index) {
      activeIndex = 0
    }
    themeList = themeList.filter((item, i) => i != index)
    this.setTheme(themeList[activeIndex], activeIndex)
    AppStorage.setOrCreate(ThemeStorageKey.THEMELISTSTR, JSON.stringify(themeList))
    AppStorage.setOrCreate<ThemeItem[]>(ThemeStorageKey.THEMELIST, themeList)
  }
}

// 单例模式
export const themeManager = new ThemeManager()