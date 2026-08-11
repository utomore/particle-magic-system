# ADR-0007：effectful 效果邊界，核心零 IO

- 狀態：已採納（2026-08-11，effectful 由 Init.md 指定）
- 相關：[architecture.md §2](../architecture.md)

## 背景

Init.md 指定使用 effectful 作為效果系統，且要求核心模組必須純函數。本 ADR 記錄效果系統的**使用範圍**——這比選哪套框架更重要：效果系統用在哪裡、更重要的是**不**用在哪裡。

## 決策

1. **`Magic.*`（核心＋邊界層）完全不出現 effectful**——不是「用 `Eff` 寫得很純」，而是型別簽名裡根本沒有 `Eff`。核心是普通純函數；內部必要的 mutable 操作以 `ST` 封裝。
2. effectful 只存在於外殼 `App.*`，以具名效果切分 IO 面積：

```haskell
data Raylib    :: Effect   -- 視窗/繪製（封裝 begin/end 配對為 bracket）
data FileWatch :: Effect   -- 魔法陣檔案監看
data Clock     :: Effect   -- 時間來源（可替換為虛擬時鐘做測試）

runApp :: Eff '[Raylib, FileWatch, Clock, IOE] ()
```

3. 主迴圈以 accumulator 實作固定時步：渲染幀率可變，模擬時步固定（力場層確定性的前提）。

## 後果

**正面**：
- 「核心可以在沒有 effectful、沒有 raylib 的環境下編譯與測試」是可機械檢查的性質（未來以 cabal internal library 的依賴清單強制）。
- 效果具名化讓外殼可測：`Clock` 換成虛擬時鐘即可無視窗跑完整個魔法生命週期。
- effectful 是具體 monad（非 mtl 風格多型），效能開銷小、錯誤訊息好，適合遊戲主迴圈。

**負面**：
- raylib 的命令式配對 API（begin/end）封裝成效果需要一次性樣板成本。
- 團隊/未來貢獻者需要理解 effectful 的 static/dynamic dispatch 概念，學習成本存在但屬一次性。
- 「核心不碰 Eff」表示核心無法自己發ログ或報進度；診斷資訊必須設計成回傳值的一部分（如 `CompileError`、統計結構）——這其實是好的設計壓力，但寫起來多一步。

## 被否決的替代方案

- **核心也用 `Eff`（純效果如 `Reader`/`State`）**：看似統一，實則讓「核心是否純」從型別可見性退化為程式碼審查問題，且核心測試被綁上效果框架。純函數不需要效果系統來表達。
- **mtl / transformers**：生態成熟，但 n² instance 問題與效能特性（深疊 monad transformer 在主迴圈）不如 effectful；且 Init.md 已指定。
- **裸 IO 外殼（不用效果系統）**：最簡單，但檔案監看/時鐘/渲染混在一起無法替換測試；effectful 的成本足夠低，值得。
