---
id: subarch-0005
type: subarch
title: render-shell
description: demo 外殼與全部 IO：主迴圈、raylib 後端、後處理與面板
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0007, adr-0009, adr-0013, adr-0018]
---

# 渲染外殼 子系統架構

## 定位與範圍

[主架構 §2.1](architecture.md#21-子系統劃分) 六塊裡唯一**不純**的一塊。整個專案所有的 IO——開視窗、讀時鐘、讀檔案、呼叫 GPU——都在這裡，其餘五塊加起來一行 IO 都沒有（ADR-0007）。

它同時是一個**證明**：這一塊整組刪掉，庫還是完整的。它消費 [subarch-0004](subarch-0004-boundary-host.md) 的 `FrameOutput`，反過來沒有任何庫元件依賴 `App.*`——這由 cabal 結構強制（executable 只依賴 `magic-boundary`，構不到 `magic-core`）。demo 是庫的第一個宿主，不是庫的一部分。

**做**：

- 固定時步主迴圈與視角／輸入狀態機
- 魔法陣檔案的熱重載與清單熱掃描
- h-raylib 的 3D 後端（動態 quad mesh）與 2D 正交後端
- 深度排序、跨批交錯、貼圖 atlas、分塊上傳
- 自訂 shader、bloom 三 pass 鏈、軟粒子
- HUD、錯誤上屏、demo 內即時參數面板

**明確不做**：

- **不定義任何對外合約**。這裡的每一個型別都可以明天換掉。唯一的例外是它**消費**的那些型別，而那些屬 subarch-0004。
- **不含魔法語意**。`App.Panel` 想改一個參數，走的是「把 `Circle` 的正規 JSON 改一個鍵再重新載入」——因為這一層**看不到 ADT**（`magic-core` 依設計構不到，`Magic.Interface` 也只不透明地匯出 `Circle`）。這不是繞路，是邊界正在生效的證據。
- **不把 shader 或 GPU 概念推回庫裡**。ADR-0018 鬆綁的是「殼層能不能用 shader」，不是「渲染細節能不能進庫」。玩家在 JSON 裡寫 GLSL 是**永久非目標**。

## 需求說明

1. **看得見**：POC 要能一眼看出魔法陣資料改了之後畫面怎麼變——所以熱重載與 HUD 是第一輪就要有的東西，不是後來補的。
2. **可測**：raylib 是命令式 IO API，但主迴圈的邏輯（步進、視角、重載決策、HUD 文字）必須能在**沒有視窗**的情況下測。
3. **draw call 數 = batch 數**，不是粒子數（ADR-0009）。
4. **零漣漪**：每一項視覺增強都要能單獨關掉，且全關時的輸出與該功能不存在時逐位元相同。四項產品級特效各自一個按鍵、預設全關，正是這條律的兌現。

## 架構規劃

分三群：**效果定義與純決策**、**渲染管線**、**IO 解釋器**。

| 元件 | 檔案 | 群 | 職責 |
|---|---|---|---|
| 效果定義 | `app/App/Effects.hs` | 定義 | `Clock`／`FileWatch`／`Raylib` 三個 effect 的**定義**（不含解釋器）、`Camera`／`ViewMode`／`FlatView`、`HudView`／`PanelView`／`DemoInput` 等渲染器無關的觀測與輸入詞彙 |
| 主迴圈 | `app/App/Loop.hs` | 決策 | `runLoop`、`ViewState` 與視角輸入的純轉移、法術清單合併、深度色調／壓平強度等呈現常數 |
| 熱重載 | `app/App/HotReload.hs` | 決策＋IO | 純決策（`stampChanged`／`reloadPoints`）與 IO 輪詢（`checkStampIO`／`scanDirIO`）分開匯出 |
| 相機 | `app/App/Camera.hs` | 決策 | 軌道座標 `Orbit`、`orbit`／`dolly` 與其上下界 |
| 3D 後端 | `app/App/Render/Raylib3D.hs` | IO | **唯一碰 h-raylib 的模組**，`Raylib` effect 的 IO 解釋器 |
| headless 後端 | `app/App/TestInterp.hs` | IO | 測試用的純解釋器，讓整套測試不需要 h-raylib 也不需要視窗 |
| quad 建構 | `app/App/Render/Quads.hs` | 管線 | `buildQuads`／`billboardBasis`、速度拉伸的 `buildTrailQuads`、多形狀合併的 `buildMergedQuads` |
| 2D 後端 | `app/App/Render/Flat.hs` | 管線 | `buildFlatQuads`、螢幕映射 `screenOf`／`panBy`／`zoomAt`／`resizeTo` |
| 排序與交錯 | `app/App/Render/Order.hs` | 管線 | `viewOrder` 深度排序、`crossBatchPicks`／`frameDraws` 跨批交錯 |
| 分塊 | `app/App/Render/Chunk.hs` | 管線 | 超過 GPU 上傳粒度（`Word16` 索引上限）的 batch 分塊繪製 |
| 貼圖 | `app/App/Render/Sprite.hs` | 管線 | 程序生成的 billboard 貼圖與 atlas（零外部圖檔） |
| shader 資產 | `app/App/Render/Shader.hs` ＋ `assets/shaders/*` | 管線 | `ShaderId`／`shaderAssets`／`shaderUniforms`，資產清單以純資料表達 |
| 後處理計畫 | `app/App/Render/Post.hs` | 管線 | `VisualSettings`、`FramePlan`／`Pass`／`Target`：**純計畫**，bloom 三 pass 與軟粒子要用幾張 render target 在這裡算完 |
| HUD ／ 面板 ／ 場景 | `app/App/Hud.hs`、`app/App/Panel.hs`、`app/App/Scene.hs` | 決策 | HUD 文字格式化與 FPS 平滑、參數面板的純狀態機與寫回、軟粒子驗證用的最小測試場景幾何 |

**這個子系統最重要的一條內部紀律**：純計畫與 IO 執行分離。`framePlan`、`buildQuads`、`viewOrder`、`stepPanel`、`formatHud` 全都是純函數，`Raylib3D` 只負責照著計畫呼叫 API。結果是 `test/` 裡有 30 份以上針對本子系統的測試，**一份都不需要開視窗**。

## 對外介面

本子系統**沒有**對外凍結介面——它是終端消費者。它的「介面」是兩個方向：

**往內消費**（只准這一條路）：

```haskell
import Magic.Interface   -- castSpell / advanceSpell / observeSpell / FrameOutput
import Magic.Codec       -- loadCircle / renderLoadError
import Magic.Projection  -- orthographic / depthOrder
import Magic.Step        -- plan（與 C ABI 的 pm_advance 共用同一個規劃器）
```

**往外呈現**：demo 執行檔 `particle-magic` 與其鍵盤操作（切法術、切視角、軌道相機、四項特效各一鍵、開關參數面板）。這些是**呈現選擇**，明文不凍結（func-0008 對 `fvOrigin`／`fvPixelsPerUnit` 的判斷）。

## 使用的技術

| 選型 | 理由 |
|---|---|
| **h-raylib 5.6** | 主架構既定。首次建置需編 raylib 的 C 原始碼，是整個技術棧風險最高的一點（§9.1），已由 func-0001 的骨架階段最先驗證 |
| **動態 quad mesh ＋ `c'` 指標 API**（ADR-0009） | instancing 經實證否決：h-raylib 的綁定無 per-instance 顏色且需自訂 shader。改走每 batch 一次 `DrawMesh`，draw call 數 = batch 數 |
| **effectful 2.6** | 三個 effect 各有 IO 與 headless 兩個解釋器；`withWindow`／`withFrame` 用 bracket 封裝 raylib 的配對呼叫 |
| **自訂 GLSL shader**（ADR-0018） | 取代 ADR-0009 的「不自訂 shader」前提。軟粒子要取樣深度、bloom 要亮度萃取與模糊，兩者都無法用預設管線做。**繪製路徑保留不變** |
| **貼圖 atlas 做跨批交錯** | 原規格的「每 batch 一個 permutation」無法兌現全域順序（batch 仍連續繪製）。改以 atlas 讓全體 alpha 粒子進同一次 draw；副作用是 draw call 反而更少（一幀最多兩次），代價是 texcoord 由開機寫一次變成每幀上傳（ADR-0018 D5） |
| **輪詢而非 fsnotify** | ADR-0005 既定延後，func-0014 §8-2 再次明文不做——10 個檔案規模下輪詢零成本 |

## 架構圖

```text
                    FrameOutput（來自 subarch-0004，零 raylib 型別）
                                      |
  +-----------------------------------+-----------------------------------+
  |                          App.Loop（固定時步主迴圈）                     |
  |   Magic.Step.plan -> n 步  |  ViewState 轉移  |  法術清單合併            |
  +--+--------------------------------+--------------------------------+--+
     |                                |                                |
     v                                v                                v
+-----------------+   +--------------------------------+   +------------------+
| App.HotReload   |   |        渲染管線（全純）           |   | App.Hud/Panel    |
|  純決策：        |   |                                |   |  formatHud       |
|   stampChanged  |   |  Order.viewOrder（深度排序）     |   |  stepPanel（純    |
|   reloadPoints  |   |         |                      |   |   狀態機）        |
|  IO：輪詢時間戳   |   |  Quads.buildQuads / Trail      |   |  寫回：改正規 JSON|
|      掃描目錄     |   |  Flat.buildFlatQuads（2D）     |   |   再重新載入      |
+--------+--------+   |         |                      |   +---------+--------+
         |            |  Sprite.atlas（程序生成貼圖）    |             |
         |            |  Chunk.chunkBatch（Word16 上限）|             |
         |            |  Order.frameDraws（跨批交錯）    |             |
         |            |  Post.framePlan（bloom 三 pass  |             |
         |            |    ＋ 軟粒子的 target 計畫）      |             |
         |            +---------------+----------------+             |
         |                            |                              |
         +----------------------------+------------------------------+
                                      |  App.Effects 的三個 effect
                        +-------------+-------------+
                        v                           v
          +---------------------------+  +---------------------------+
          | App.Render.Raylib3D       |  | App.TestInterp            |
          |  唯一碰 h-raylib 的模組     |  |  headless 解釋器           |
          |  ＋ assets/shaders/*.vs/fs |  |  測試不需要視窗            |
          +-------------+-------------+  +---------------------------+
                        v
                    視窗 / GPU
```

## 資料結構的框架格式

- **effect 定義**：`data Raylib :: Effect` 等三個 GADT 風格的 effect 型別，操作以建構子表達；解釋器在別的模組。
- **視角狀態**：`ViewState` 是純 record（相機軌道 ＋ `ViewMode` ＋ 2D 的 `FlatView`），輸入以 `DemoInput` 這個渲染器無關的詞彙進來，轉移是 `applyViewInput` 這個純函數。
- **後處理計畫**：`FramePlan` 是 `[Pass]`，每個 `Pass` 帶來源 `Target`、目標 `Target`、`PassSize`。要幾張 scratch target 由 `scratchTargetsNeeded` 從計畫算出——**分配之前就知道要幾張**。
- **面板**：`PanelState` 是純狀態機，`ParamPath` 指向 JSON 中的一個位置，`applyParam` 產生新的正規 JSON。`PanelAction` 表達鍵入、確認、放棄、存檔。
- **貼圖**：`atlasTexels` 產生的是 `Word32` 像素陣列，開機時上傳一次；atlas 內每種形狀的區域由 `atlasRect` 查得。

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `h-raylib` | 視窗、輸入、mesh、shader、render target |
| `effectful` | 三個 effect 的定義與解釋 |
| `aeson` | 參數面板改寫正規 JSON（本層看不到 ADT，只能走 JSON） |
| `bytestring`／`vector`／`containers` | 緩衝與清單處理 |
| `directory`／`filepath`／`time` | 熱重載的檔案輪詢與時間戳 |

## 開發階段

對應主架構的 POC 實作階段的「看得見」那一半。內部里程碑四個：**M1 畫得出來**（單 draw call、HUD、錯誤上屏）、**M2 看得清楚**（深度排序、軌道相機、2D 平移縮放、俯視可讀性）、**M3 看的是什麼**（形狀詞彙、逐 batch 貼圖）、**M4 值得看**（拖尾、bloom、軟粒子、跨批交錯）。四者皆已達成。

## 功能規劃

### 階段一：畫得出來（M1，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | render-observability | 動態 quad mesh 單 draw call、HUD、錯誤上屏、熱重載回饋 | - | func-0005 |
| 2 | ortho2d-shell | 2D 正交後端的殼層半場：投影切換、painter 排序、螢幕映射（核心半場見 subarch-0004） | #1 | func-0008 |

### 階段二：看得清楚（M2，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 3 | visual-expressiveness | 3D alpha 深度排序、軌道相機、2D 平移縮放與視窗適配、俯視深度色調 | #2 | func-0013 |

### 階段三：看的是什麼（M3，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 4 | visual-vocabulary | 依 `(blend, shape)` 分批的多批次繪製 ＋ 逐 batch 程序生成貼圖（詞彙半場見 subarch-0001） | #3 | func-0015 |

### 階段四：值得看（M4，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 5 | production-visuals | 速度驅動的拖尾、bloom 三 pass、深度取樣的軟粒子、貼圖 atlas 的跨批交錯；四項各一鍵、預設全關 | #4 | func-0023 |
| 6 | param-panel | demo 內即時參數面板與其寫回（走正規 JSON，因為這一層看不到 ADT） | #5 | func-0024 |

### 階段五：候選（未動工，逐條有記帳來源）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 7 | hdr-tonemapping | HDR 管線與色調映射——bloom 目前在 LDR 下做（0023 §8-5 記帳） | #5 | - |
| 8 | camera-motion | 相機動畫／過場與慣性阻尼（0013 §8-5） | #3 | - |
| 9 | pixel-art-reference | 像素風的**畫得出來**的參考實作：低解析 target 整數倍放大 ＋ 調色盤量化。食譜已寫但沒有範例走過（enhance-0001 §8） | #2 | - |
| 10 | order-introsort | 3D 深度排序目前以 `sortOn` 起步；若成為熱點可套用核心那份 in-place introsort（0013 §8-6） | #3 | - |

**明文不做**：fsnotify（ADR-0005 既定延後，func-0014 §8-2 再次確認：10 檔規模輪詢零成本）；玩家在 JSON 裡寫 GLSL（永久非目標——會把 GPU API 帶進輸入合約，破壞 ADR-0005 的可攜性）。

小結：共 **10 個 features、5 個階段**，前 6 個已交付，「特效即魔法」在畫面上已經成立；階段五四項皆為精緻化，沒有一項是缺口。
