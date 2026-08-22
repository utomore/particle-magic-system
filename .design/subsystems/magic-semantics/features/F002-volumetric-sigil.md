---
id: F002
type: feature
title: volumetric-sigil
description: 陣的opt-in立體堆疊，層數由結構導出，單層時逐位元不變
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001]
related-adr: [adr-0014, adr-0019, adr-0020]
related-feature: []
---

# F002: 陣的立體堆疊（volumetric-sigil）

> 本文檔在委派模式下產出（依 `dev-flow` delegation 契約）：輸入是 `.design/subsystems/magic-semantics/design.md` 的 `volumetric-sigil` 契約卡與 2026-08-22 批次澄清，未經開發者訪談；不確定的判斷記在文末「待確認假設」。

## 功能概述

`Magic.Sigil.sigilPlan` 交付以來，一張陣永遠是單一平面：筆畫都畫在面座標的 `z = 0`。本輪加一個**陣層級 opt-in 屬性**，開啟後把陣形（筆畫與外圈預覽形狀）沿法線複製成數層平行的平面，層數由陣的**槽位結構**（哪些環/夾層被填）決定，不是玩家直接指定,也不進 `hashCircle` 的摘要。

**驗收標準**（契約卡逐字）：

1. 陣由單一平面變成多層平面沿法線堆疊。
2. 堆疊是 opt-in 的陣層級屬性；沒有這個屬性的魔法陣一律單層,輸出逐位元不變。
3. 有這個屬性時,實際層數由結構導出。
4. 結構摘要（`hashCircle`）不因這個屬性改變。

**明確不做**：不改變「陣是被畫出來的線」這個前提（沒有新的筆畫種類、沒有新的取樣方式）；不做層與層之間的動態互動（層與層互不感知，沒有跨層的力或碰撞）；不讓層數在沒有屬性的情況下自行大於 1。

## 相依性

介面表（見下）逐列查過的每一個既有函式，多數來源是**已交付的舊體系規格**（func-0002／0006／0010／0016／0017／0020／0025），在 `magic-semantics/design.md` 的「已交付（歷史）」一節皆標為 `status: done`，且本輪引用它們的方式都是「原樣呼叫、簽名不動」——這些不是本系統 `depends-on` 追蹤的 id 空間（沒有 F 前綴），純粹經 `legacy-map.md` 指到 `docs/spec/`。

但介面表有兩列的「來源文檔」實際落在 `magic-semantics/F001`（sigil-time-axis，`status: done`，程式碼已合併）：

- `formationAppearance` 目前的簽名是 `Bool -> Element -> Appearance`——這個 `Bool`（`hold`）參數是 F001 加的，本輪原樣呼叫這個已經是雙參數版本的函式，不是 func-0006 交付時的單參數版本。
- `formEnvFor` 的呼叫端第二參數（`sigilEnd`）由 F001 從 `spellEnd` 換算而來；`formEnvFor` 本身的型別簽名仍是 func-0017 的，但本輪讀到的 `sigilEnd` 這個值是 F001 引入 `circleSigil`／`stLinger` 之後才存在的運算式。

因此依「候選 depends-on 反推」的規則（見文末一致性檢查），F001 必須進 `depends-on`——即使它已 `status: done`、不會阻塞任何平行開發，仍是介面表指名的真實相依，不能因為「反正已經做完了」就從相依性欄位裡拿掉。

**結論：`depends-on: [F001]`**。F001 已交付，不阻塞本輪動工；本輪也可與子系統內其他任何**不同時改 `Magic.Circle`／`Magic.Codec`／`Magic.Compile`／`tools/Schema.hs` 這四個檔案**的進行中任務平行開發（本文撰寫時子系統內沒有其他進行中的任務）。

## 對應的 Level 2 契約

- **擴充 C4.2（陣形計畫）**：筆畫「帶沿法線的層次偏移」——本輪的實作把這個偏移放在**每個發射器自己的 `Anchor`**（見下方「實作方式 §1」的三案評估），而不是改 `SigilStroke` 的欄位形狀；`SigilPlan`／`SigilStroke` 本身一行不動，`Magic.Sigil` 模組全部凍結介面（`hashCircle`、`sigilPlan`、`strokeRadius`、`sampleStroke`、`spinAngle`）維持逐位元不變。這是 Level 3 的實作自主權範圍內的選擇：C4.2 承諾的是「筆畫計畫產生的幾何帶層次偏移」這個外顯效果，不是鎖死偏移量必須活在 `SigilStroke` 的哪個欄位。
- **擴充 C3.2（空間包絡，僅堆疊開啟時加寬）**：`Magic.Compile.emitterBounds` 與 `Magic.Space.emitterBox`／`spellBounds`／`spellBox` 的函式本體**一行不改**。加寬完全由「同一份陣形在堆疊開啟時產生更多個、錨點沿法線互相錯開的 `EmitterSpec`」這件事在下遊自動發生——這些函式本來就是逐 emitter 算好之後再對 `spellEmitters` 做 union，錨點多錯開幾公分，union 出來的包絡自然變寬,不需要多一個分支。詳見「實作方式 §5」。
- **新增一個陣層級屬性到 M2（結構）**：`Circle` 加第五個 `Maybe` 欄位 `circleVolume :: !(Maybe SigilVolume)`，形狀完全比照 `circlePhases`／`circleFields`／`circleAnchors`／`circleSigil` 的既有慣例。

未超出 Level 2 契約：沒有新增編譯錯誤、沒有新的匯出模組、`CompiledSpell` 的六個組成欄位形狀不變（只是 `spellEmitters` 這個 `Vector` 在堆疊開啟時多幾個元素，這本來就是「發射器集合」的既有彈性——`circleAnchors` 一輪也一樣讓它變多）。

## 實作方式

### 1. 層次偏移放哪裡：三案評估

契約卡要求評估三個位置，逐一檢視：

| 方案 | 做法 | 代價 |
|---|---|---|
| **A. `SigilStroke` 加欄位** | 加 `skLayerOffset :: Float`，`sampleStroke`/`strokeCurve` 讀它 | 動 `Magic.Sigil`（凍結模組，`hashCircle`/`sigilPlan` 這兩個 func-0016 交付即凍結的介面都在同一個檔）；`strokeRadius`（`emitterBounds`/`Magic.Space` 的半徑上界依據）要不要吃這個欄位又是一次判斷；且一個 `SigilStroke` 現在對應「一整組同心層」還是「一層」變得歧義 |
| **B. `SpawnPattern` 加建構子**（如 `SpawnOnStrokeLayered SigilStroke Float`） | 新增一個 sum 成員 | `Magic.Compile.emitterBounds`（`spawnRadius` 的 case）、`Magic.Space.emitterBox`（同一個 case 兩份）、`Magic.Particle.Analytic.positionIn`（`V2 sx sy` 的 case）三處全部要多一個分支，且都是「窮盡性檢查會抓到，但抓到的地方離真正的邏輯很遠」的散彈式修改 |
| **C. `Anchor` 的偏移**（採用） | 同一個 `SigilStroke`／`SpawnPattern` 值,原樣複製成 N 個 `EmitterSpec`,只有 `emAnchor` 的 `anchorOffset` 的 z 分量（面座標,沿法線）不同 | 只動 `Magic.Compile.formationEmittersFor` 這一個函式；`Anchor` 型別本身（func-0025 交付）一行不改，只是「用它的既有方式構造更多個值」 |

選 **C**。三個理由：

1. **`Anchor` 的語意本來就是「沿法線的偏移」**：`anchorOffset :: V3` 在呼叫端一路被 `toWorld` 解成 `(caster 右, caster 上, casterFacing)`，而 `originAnchor = Anchor {anchorOffset = V3 0 0 0, anchorNormal = V3 0 0 1}` 已經證明 z 分量就是「沿 `casterFacing`（＝這一輪唯一在用的法線）位移多少」——四個節點發射器的 `V3 0 0.35 0` 用的正是同一個座標系的 x/y 分量，只是這次改用 z。這不是新語意，是既有語意的第一次啟用。
2. **`emitterBounds`／`Magic.Space` 的函式簽名只吃 `EmitterSpec`,不吃 `Circle`**：既然層次偏移最終要進到這兩個「C3.2」函式的計算裡,而它們的唯一輸入管道就是 `emAnchor`,選 A 或 B 都要多繞一手（讓 `SigilStroke`/`SpawnPattern` 攜帶偏移,再讓這兩個函式學會讀它）,選 C 直接命中它們已經在讀的欄位。
3. **`Magic.Sigil`（M5）維持逐位元凍結,門槛最低**：`hashCircle`／`sigilPlan`／`strokeRadius`／`sampleStroke`／`spinAngle` 五個 func-0016／0020 交付即凍結的介面,選 C 之後一行都不用碰,和 F001 對 `circleSigil` 的處理是同一個判斷（"不做事就是最便宜的正確實作"）。

### 2. 層數由結構導出

`stackDepth`（`Magic.Compile` 內部,不匯出）：

```haskell
stackDepth :: Circle -> Int
stackDepth c = case circleVolume c of
  Nothing -> 1
  Just SigilVolume -> min 5 (max 2 (1 + occCount))
  where
    occCount =
      length
        ( filter
            id
            [ isJust (ringB (outerRings c))
            , isJust (ringA (outerRings c))
            , isJust (interLayer c)
            , isJust (ringB (innerRings c))
            , isJust (ringA (innerRings c))
            ]
        )
```

依 ADR-0014 D2「混合導出：結構定骨架、摘要定花紋」——層數屬骨架那一側，所以只讀五個槽位是否為 `Just`（**不呼叫 `hashCircle`，不讀任何符文的值域**），與 `sigilPlan` 內部 `symCenter = clampI 3 9 (3 + occCount)` 用的是同一種「結構計數」手法，但這是**兩個獨立的計算**（不共用程式碼、不透過 `Magic.Sigil` 傳遞）：`sigilPlan` 的 occCount 是 M5 的私有細節，`stackDepth` 的 occCount 是本輪在 M4 對 `Circle` 原始欄位的重新計數，兩者恰好同構只是巧合般的自洽,不是耦合。

`circleVolume = Nothing` ⇒ `stackDepth = 1`（單層,相容律的建構基礎）。`Just SigilVolume` ⇒ 層數落在 `[2, 5]`，全空的陣（`occCount = 0`）開啟屬性後得到下界 2 層（仍然可觀察到「變厚了」），五槽全滿得到上界 5 層。

### 3. 每層的錨點與粒子配額

```haskell
layerGap :: Float
layerGap = 0.12   -- 面座標單位，與 sigilPlan 的 radii 帶（0.70–1.50）同量級

layerAnchor :: Int -> Int -> Anchor
layerAnchor depth k =
  originAnchor {anchorOffset = V3 0 0 (layerGap * (fromIntegral k - 0.5 * (fromIntegral depth - 1)))}

perLayerCount :: Int -> Int -> Int -> Int
perLayerCount total depth arms =
  ((total `div` max 1 depth) `div` max 1 arms) * max 1 arms
```

`layerAnchor` 把 `depth` 層對稱地攤在 `z = 0` 兩側（`depth` 為奇數時中間一層剛好落在 `z = 0`，即原本單層的位置）；`depth = 1` 時 `layerAnchor 1 0 == originAnchor`——**逐位元**，不是數值上湊巧接近。

`perLayerCount` 把一筆畫／一形狀預覽的既有總數 `total`（`skCount`／shape 的 `Int`）均分到 `depth` 層，且捨到 `arms`（`skSymmetry`，形狀預覽視為 `arms = 1`）的倍數——與 `Magic.Sigil.sigilPlan` 自己 clip 超預算時「捨到 arms 倍數」是同一個理由：每個 arm 拿到一樣的點數，曲線參數才能收在 `[0,1]` 收尾。`depth = 1` 時 `perLayerCount total 1 arms == total`（`sigilPlan` 保證 `total` 本來就是 `arms` 的倍數，見 `Magic.Sigil` 對 `skCount` 的文件註解）。

**跨層總和恆不大於原本單層總量**：`depth` 層每層 `perLayerCount total depth arms`，總和 `<= total`（等號只在整除時成立，餘數被捨去，與 `sigilPlan` clip 現有風格一致：「不夠一個 arm 的份寧可丟掉，不做部分 arm」）。因此**堆疊不會讓 `sigilBudget`（1536）或 `budgetCap` 的護欄語意變寬**：開啟堆疊只是把既有粒子數攤薄到更多層，從不新增。這是本文檔對「粒子預算怎麼分」這道設計題的答案——不新增預算維度，也不需要新的 `CompileError`。

### 4. `formationEmittersFor` 的改法

只動「筆畫」與「外圈預覽形狀」兩類（`spStrokes`／`spShapes`），**節點與中心點發射器不參與堆疊**（見「待確認假設」A2）：

```haskell
formationEmittersFor circle castStart sigilEnd element =
  concat
    [ concat [layeredEmitters (SpawnOnStroke sk) (skCount sk) (max 1 (skSymmetry sk)) | sk <- V.toList (spStrokes plan)]
    , concat [layeredEmitters (SpawnOnShape shape) cnt 1 | (shape, cnt) <- V.toList (spShapes plan)]
    , nodeSlotEmitter 12 (V3 0 0.35 0) (north (coreNodes (core circle)))   -- 不變
    , nodeSlotEmitter 12 (V3 0 (-0.35) 0) (south (coreNodes (core circle))) -- 不變
    , nodeSlotEmitter 12 (V3 0.35 0 0) (east (coreNodes (core circle)))    -- 不變
    , nodeSlotEmitter 12 (V3 (-0.35) 0 0) (west (coreNodes (core circle))) -- 不變
    , centerSlotEmitter 16 (coreCenter (core circle))                     -- 不變
    ]
  where
    plan = sigilPlan circle          -- 不變：呼叫方式與既有一致
    formEnv = formEnvFor castStart sigilEnd                                    -- 不變，跨層共用同一個envelope
    appearance = formationAppearance (maybe False stHold (circleSigil circle)) element  -- 不變
    depth = stackDepth circle

    layeredEmitters spawn total arms =
      [ EmitterSpec
          { emAnchor = layerAnchor depth k
          , emCount = perLayerCount total depth arms
          , emSpawn = formEnv
          , emMotion = formationMotion spawn
          , emAppearance = appearance
          , emPhase = Drawing
          , emCode = noEmitterCode
          }
      | k <- [0 .. depth - 1]
      ]
```

`depth = 1`（即 `circleVolume circle == Nothing`）時 `layeredEmitters spawn total arms` 化簡回「一個 `ringSlotEmitter total spawn`」——`layerAnchor 1 0 == originAnchor`、`perLayerCount total 1 arms == total`，整個 `concat` 產生的清單與交付前的 `formationEmittersFor` 逐位元相同（驗收 2 的實作依據，和 F001 對 `sigilEnd` 的證法同一套：**退化成交付前的原式，不是測出來剛好一樣**）。

### 5. C3.2 的加寬：為什麼不改 `emitterBounds`／`Magic.Space`

`emitterBounds :: CastContext -> Seconds -> EmitterSpec -> (V3, V3)` 只吃單一 `EmitterSpec`；`Magic.Space.spellBounds`／`spellBox` 對 `spellEmitters` 做 union。堆疊開啟後 `formationEmittersFor` 產生的是**更多個** `EmitterSpec`（每個錨點沿法線錯開 `layerGap`），這兩層函式完全不需要知道「堆疊」這個概念存在——它們本來就是「對每個 emitter 算一個立方體／一個 fitted box，再對所有 emitter 取聯集」，錨點多錯開幾個位置，聯集自然變寬。

**這正是「僅在堆疊開啟時加寬」與「回傳的一定是立方體」兩條律同時成立的原因**：

- 沒開堆疊：`depth = 1`，`formationEmittersFor` 的輸出逐位元不變 ⇒ 餵給 `emitterBounds`／`Magic.Space` 的 `EmitterSpec` 逐位元不變 ⇒ 兩層函式的輸出當然也逐位元不變——`test/SpaceBoundsSpec.hs` 現有的 golden（`test/golden/emitter-bounds-0025.txt`）與「一律是立方體」的斷言不需要重錄一行，因為函式本體真的沒有被改到。
- 開了堆疊：每個 emitter 的 `emitterBounds` 仍然是以它自己的（已錯開的）錨點為中心的立方體——**單一 emitter 的回傳值仍然是立方體**（半徑計算完全不知道其他層的存在），律 1 成立；`Magic.Space.spellBounds`／`spellBox` 對多個彼此錯開的立方體取聯集，聯集自然比單一居中立方體寬——律 2（僅堆疊開啟時加寬）由「union 的輸入變多了」這個事實直接得到，不需要新寫一個 if 分支。

### 6. Codec 與 Schema

比照 `circleSigil`（F001）與 `circleAnchors`（func-0025）的既有形狀，`SigilVolume` 是這批屬性裡**唯一沒有可調參數的一個**——目前設計成純粹的開關：陣層級鍵存在（且不是 `null`）就是「開」，鍵的內容本身被忽略（呼應 `"sigil": {}` 合法且是 no-op 的先例，但這次連解析出來的值都固定是同一個 nullary 建構子，不像 `sigil` 那樣有 `linger`/`hold` 兩個欄位）：

```haskell
-- Magic.Codec
parseSigilVolume :: Value -> Parser SigilVolume
parseSigilVolume = withObject "volume" $ \_o -> pure SigilVolume

encodeSigilVolume :: SigilVolume -> Value
encodeSigilVolume SigilVolume = object []
```

`parseCircle` 加一行 `volume <- parseSlot "volume" parseSigilVolume o`，`Circle` 建構加 `circleVolume = volume`；`saveCircle` 加一列 `"volume" .= maybe Null encodeSigilVolume (circleVolume circle)`。JSON 鍵 `"volume": null` 或缺鍵 ≡ 無鍵（`slotValue` 既有語意）；`"volume": {}` 或 `"volume": {"anything": 1}` 皆 ≡ `Just SigilVolume`（內容被忽略，不是欄位放寬,是型別上本來就沒有欄位可讀）。

`tools/Schema.hs` 新增 `volumeDef`（零屬性物件,`properties` 為空物件）,`circleDef` 的 `properties` 加 `("volume", nullable (ref "volume"))`,排在 `sigil` 之後；`definitions` 加 `("volume", volumeDef)`。`docs/spell.schema.json` 以 `cabal run magic-schema -- --out docs/spell.schema.json` 重生成。

`docs/spell-schema.md`：§8 標題由「選配：`phases`、`fields`、`anchors` 與 `sigil`」改為再加 `volume`；新增 §8.5 說明「presence 即開關、內容被忽略、層數由結構導出、單層時逐位元不變」；§11 範例導覽加一列新出貨陣。

### 7. 新示範陣

`assets/spells/stacked-sigil.json`：外圈 A/B、夾層、內圈 A/B 五槽全部填值（`occCount = 5` ⇒ `stackDepth` 落在上界 5）＋ `phases`（沒有它 `formationEmittersFor` 根本不會被呼叫，堆疊無從觀察，此為「無 phases 時惰性」的自動推論，不需要額外程式碼）＋ `"volume": {}`。刻意不設 `"sigil"` 鍵，保持與 F001 的屬性正交、互不干擾（兩者可以同時開，但示範陣一次只驗一個新屬性,降低回歸面）。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Circle = Circle { outerRings :: TwoOf (Maybe OuterRune), interLayer :: Maybe BridgeRune, innerRings :: TwoOf (Maybe InnerRune), core :: Core, circlePhases :: !(Maybe PhaseConfig), circleFields :: ![ForceField], circleAnchors :: !(Maybe [Anchor]), circleSigil :: !(Maybe SigilTiming) }` | `src/core/Magic/Circle.hs` | func-0006（欄位陸續由 func-0007／0025／magic-semantics/F001 加） | 加第五個陣層級欄位 `circleVolume`；`stackDepth` 讀 `outerRings`/`interLayer`/`innerRings` 判斷 occCount |
| `data TwoOf a = TwoOf { ringA :: a, ringB :: a }` | `src/core/Magic/Circle.hs` | func-0006 | `stackDepth` 讀兩個環的占用狀態 |
| `emptyCircle :: Circle` | `src/core/Magic/Circle.hs` | func-0006 | 新欄位的預設 `Nothing` |
| `formationEmittersFor :: Circle -> Seconds -> Seconds -> Element -> [EmitterSpec]` | `src/core/Magic/Compile.hs` | func-0017 | 本輪唯一改動函式本體的地方；簽名不變，內部由已在作用域的 `circle` 讀 `circleVolume` |
| `data EmitterSpec = EmitterSpec { emAnchor :: !Anchor, emCount :: !Int, emSpawn :: !Envelope, emMotion :: !Motion, emAppearance :: !Appearance, emPhase :: !Phase, emCode :: !EmitterCode }` | `src/core/Magic/Compile.hs` | func-0002／0006／0022 | 每層一個值，只有 `emAnchor`／`emCount` 隨層變化 |
| `data Anchor = Anchor { anchorOffset :: !V3, anchorNormal :: !V3 }` | `src/core/Magic/Rune.hs` | func-0025 | `layerAnchor` 用它既有的 `anchorOffset` z 分量表達沿法線的層次位移 |
| `originAnchor :: Anchor` | `src/core/Magic/Compile.hs` | func-0006（func-0025 加註記） | `layerAnchor` 以它為底座做記錄更新；`depth = 1` 時退化為它本身 |
| `data SigilPlan = SigilPlan { spSymmetry :: !Int, spStrokes :: !(V.Vector SigilStroke), spShapes :: !(V.Vector (FaceShape, Int)) }` | `src/core/Magic/Sigil.hs` | func-0016 | **不改**；`formationEmittersFor` 對 `spStrokes`/`spShapes` 的每個元素跑 `layeredEmitters` |
| `data SigilStroke = SigilStroke { skKind :: !StrokeKind, skRadius :: !Float, skSymmetry :: !Int, skPhase :: !Float, skJitter :: !Float, skCount :: !Int, skSpin :: !SigilSpin }` | `src/core/Magic/Sigil.hs` | func-0016／0020 | **不改**；讀 `skCount`／`skSymmetry` 算 `perLayerCount` 的輸入 |
| `sigilPlan :: Circle -> SigilPlan` | `src/core/Magic/Sigil.hs` | func-0016 | **不改**，呼叫方式與既有一致（每次 compile 呼叫一次） |
| `hashCircle :: Circle -> Word64` | `src/core/Magic/Sigil.hs` | func-0016 | **不改**；`circleVolume` 不進摘要（ADR-0014 D3），本輪零度使用，只做為「不變」的驗證對象 |
| `strokeRadius :: SigilStroke -> Float` | `src/core/Magic/Sigil.hs` | func-0016 | **不改**；`emitterBounds`／`Magic.Space.emitterBox` 既有呼叫不受堆疊影響（半徑只描述筆畫本身,層次位移已經在 `emAnchor` 上處理） |
| `emitterBounds :: CastContext -> Seconds -> EmitterSpec -> (V3, V3)` | `src/core/Magic/Compile.hs` | func-0010 | **函式本體一行不改**；本輪只是餵給它更多個（錨點不同的）`EmitterSpec` |
| `emitterBox :: CastContext -> Seconds -> EmitterSpec -> OrientedBox`、`spellBounds :: CastContext -> Seconds -> CompiledSpell -> (V3, V3)`、`spellBox :: CastContext -> Seconds -> CompiledSpell -> OrientedBox` | `src/core/Magic/Space.hs` | func-0025 | **函式本體一行不改**；對 `spellEmitters` 的既有 union 邏輯自動把新增的錯開錨點納入 |
| `formationMotion :: SpawnPattern -> Motion` | `src/core/Magic/Compile.hs` | func-0017 | **不改**；每層原樣呼叫一次 |
| `formEnvFor :: Seconds -> Seconds -> Envelope` | `src/core/Magic/Compile.hs` | func-0017／magic-semantics/F001 | **不改**；跨層共用同一個 envelope 值（所有層同步生成/收場） |
| `formationAppearance :: Bool -> Element -> Appearance` | `src/core/Magic/Compile.hs` | magic-semantics/F001 | **不改**；跨層共用同一個外觀值 |
| `data SpawnPattern = SpawnAtAnchor !Float \| SpawnOnShape !FaceShape \| SpawnOnStroke !SigilStroke` | `src/core/Magic/Compile.hs` | func-0016 | **不改**（評估過加建構子的方案 B，未採用，見「實作方式 §1」） |
| `parseSlot :: AK.Key -> (Value -> Parser a) -> Object -> Parser (Maybe a)` | `src/boundary/Magic/Codec.hs` | - | 掛上 `"volume"` 這個 opt-in 鍵 |
| `slotValue :: Object -> AK.Key -> Parser (Maybe Value)` | `src/boundary/Magic/Codec.hs` | - | `"volume": null` ≡ 無鍵 的來源 |
| `parseCircle :: Value -> Parser Circle`、`saveCircle :: Circle -> BS.ByteString` | `src/boundary/Magic/Codec.hs` | func-0006 | 各加一行接上第五個陣層級鍵 |
| `sigilDef :: J` | `tools/Schema.hs` | magic-semantics/F001 | `volumeDef` 照它的形狀寫（零屬性物件） |

## 新增的介面

```haskell
-- src/core/Magic/Circle.hs（新增，並加入匯出清單）

-- | 陣的立體堆疊開關（feature volumetric-sigil）。第五個陣層級屬性，慣例同
-- 'circlePhases'／'circleFields'／'circleAnchors'／'circleSigil'：不是符文、
-- 不在槽位、opt-in，且 'Nothing'（'emptyCircle' 的值）維持單一平面——
-- pre-volumetric-sigil 的路徑。
--
-- 目前是純開關：沒有可調欄位，鍵存在（且非 null）即代表「開」，實際層數
-- 由 'Magic.Compile.stackDepth' 從circle 的槽位結構導出，不由這個型別自
-- 己攜帶的值決定（它根本沒有值可帶）。
--
-- 刻意不進 'Magic.Sigil.hashCircle'：這個屬性改的是陣佔多少空間，不是陣
-- 的平面長相（ADR-0014 D3）。
data SigilVolume = SigilVolume
  deriving (Eq, Show)

-- Circle 加一欄
--   , circleVolume :: !(Maybe SigilVolume)

-- src/boundary/Magic/Codec.hs（新增，皆為模組內部）
parseSigilVolume  :: Value -> Parser SigilVolume
encodeSigilVolume :: SigilVolume -> Value

-- src/core/Magic/Compile.hs（新增，皆不匯出——Level 2 只承諾其外顯效果，
-- 見「對應的 Level 2 契約」）
stackDepth    :: Circle -> Int
layerGap      :: Float
layerAnchor   :: Int -> Int -> Anchor
perLayerCount :: Int -> Int -> Int -> Int

-- tools/Schema.hs（新增）
volumeDef :: J
```

## TodoList

- [ ] T1: `Magic.Circle` 加 `SigilVolume` 型別與 `Circle.circleVolume` 欄位，`emptyCircle` 補 `Nothing`，加入匯出清單  `dep: -`
- [ ] T2: `Magic.Codec` 加 `parseSigilVolume`／`encodeSigilVolume`，接上 `parseCircle` 與 `saveCircle`  `dep: T1`
- [ ] T3: `Magic.Compile` 加 `stackDepth`／`layerGap`／`layerAnchor`／`perLayerCount`，`formationEmittersFor` 的筆畫與外圈預覽形狀改為依 `stackDepth` 產生多層 `EmitterSpec`（節點與中心點發射器不變）  `dep: T1`
- [ ] T4: 零漣漪與摘要不變的迴歸守護：`hashCircle` 不因 `circleVolume` 改變；`circleVolume = Nothing`（唯一能讓 `stackDepth == 1` 的路徑）產生的 `CompiledSpell` 與交付前逐位元相同  `dep: T3`
- [ ] T5: 結構導出律：相異 occCount 的陣得到相異且落在 `[2,5]` 的 `stackDepth`；每筆畫／形狀跨層的粒子數之和不大於原單層數量  `dep: T3`
- [ ] T6: C3.2 opt-in 加寬的驗收：`emitterBounds` 對任一 `EmitterSpec` 仍回傳立方體且數值不因堆疊改變；`Magic.Space.spellBounds`／`spellBox` 對開啟 `volume` 的陣回傳的包絡不小於未開啟時的包絡，且 containment 律仍成立  `dep: T3`
- [ ] T7: 作者面：`tools/Schema.hs` 的 `volumeDef`、重生成 `docs/spell.schema.json`、`docs/spell-schema.md` §8 標題與新的 §8.5；新示範陣 `assets/spells/stacked-sigil.json`（五槽全填 + `phases` + `"volume": {}`），並牽動既有範例清單（`test/Acceptance21Spec.hs` 的 `newSpells`、`test/Acceptance23Spec.hs` 的 `laterExamples`、`test/PerfGoldenSpec.hs` 的 `examples`、`test/SpaceBoundsSpec.hs` 的 golden 排除列表、`test/SchemaDocSpec.hs`／`test/ValidateSpec.hs` 的檔案數），以 demo 視窗做一次手動 smoke  `dep: T2, T3`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test/SigilVolumeSpec.hs` | `SigilVolume` 的 `Eq`／`Show`；`circleVolume emptyCircle == Nothing`；`Circle` 的記錄更新不影響其餘四個陣層級欄位 |
| T2 | `test/SigilVolumeCodecSpec.hs` | 往返律 `loadCircle . saveCircle ≡ id`；`"volume": null` ≡ 無鍵；`"volume": {}` 與 `"volume": {"x": 1}` 皆 ≡ `Just SigilVolume`（內容被忽略） |
| T3 | `test/SigilVolumeStackSpec.hs` | `stackDepth circle == 1` 時 `formationEmittersFor` 的輸出與未加本屬性前逐位元相同（`layerAnchor 1 0 == originAnchor`、`perLayerCount total 1 arms == total`）；`stackDepth > 1` 時每個筆畫/形狀確實產生 `stackDepth` 個 `EmitterSpec`，各自 `emAnchor` 的 `anchorOffset` 沿 z 對稱分布且互不相同，`emSpawn`／`emAppearance` 跨層相同 |
| T4 | `test/SigilVolumeInvariantSpec.hs` | `hashCircle c == hashCircle c { circleVolume = Just SigilVolume }`（任意 `c`，任何 occCount——摘要不變律不因結構而異）；`circleVolume = Nothing` 的每一張出貨陣，其 `formationEmittersFor` 輸出與同一張陣經 `layeredEmitters` 在 `depth = 1` 分支算出的清單逐位元相同（`stackDepth` 的下界是 2，`Just SigilVolume` 永遠不會落回 1，所以零漣漪律只能、也只需要對 `Nothing` 分支證明）；出貨陣掃描（`assets/spells/` 全目錄）在 240 幀內的緩衝逐位元相同（沿用 magic-semantics/F001 的差分寫法，不重錄任何既有 golden） |
| T5 | `test/SigilVolumeStructureSpec.hs` | 至少三組不同 occCount（0、部分填、五槽全填）的陣，`stackDepth` 分別為 2、居中值、5，且單調不減；任一筆畫/形狀跨層 `emCount` 之和 `<= sigilPlan` 交付的原始單層數量；`stackDepth` 恆落在 `[1,5]` |
| T6 | `test/SigilVolumeBoundsSpec.hs` | 對 `stacked-sigil.json`：每個 formation `EmitterSpec` 的 `emitterBounds` 仍是「三軸同半徑」的立方體（同 `SpaceBoundsSpec` 的斷言手法）；`spellBounds`／`spellBox` 在 `volume` 開啟時的包絡體積不小於把 `volume` 拔掉後的同一張陣；`particlePosition` 對所有活粒子仍落在 `emitterBox` 內（containment 律） |
| T7 | `test/JsonSchemaSpec.hs`、`test/SchemaDocSpec.hs`（既有律擴充）＋ `test/ValidateSpec.hs`（既有律自動涵蓋） | `docs/spell.schema.json` 與 `generateSchema` 一致且含 `volume`；`volume` 鍵出現在 `docs/spell-schema.md`；`stacked-sigil.json` 載入、編譯、施放皆成功 |

## 待確認假設

- A1：`SigilVolume` 目前設計為零欄位的純開關（鍵存在即開，內容忽略）。若後續要開放玩家調整層距或層數上限，可在型別上加欄位而不必變動 `Circle` 的形狀或 JSON 鍵本身——本假設只影響「這一輪要不要現在就留欄位」，不影響已交付後的相容性。
- A2：堆疊只套用在 `spStrokes`／`spShapes`（筆畫與外圈預覽形狀），刻意不含四個節點裝飾點與中心點發射器——這兩類是 func-0006 §4.4「畫陣階段的裝飾點」而非陣本身的筆畫。若判斷應該一併堆疊，需要在 `formationEmittersFor` 對 `nodeSlotEmitter`／`centerSlotEmitter` 套用同一組 `layeredEmitters`，且要重新評估它們固定的 12／16 顆粒子配額怎麼跨層分攤。
- A3：層數導出公式選 `min 5 (max 2 (1 + occCount))`，`layerGap = 0.12`（面座標單位）。這兩個常數屬 Level 3 實作細節，不是 Level 2 契約的一部分；手動 smoke（T7）若覺得視覺上太密／太疏，可以在實作階段直接調整數值而不需要改本文檔或重新委派，只要 `depth = 1` 時的逐位元恆等式不受影響。
- A4：每層粒子數用「均分後捨到 arms 倍數」，總和恆 `<=` 原單層總量，刻意不新增粒子預算（`sigilBudget`／`budgetCap` 都不變、不新增 `CompileError`）。若審查者希望堆疊時總粒子量跟著層數等比放大（讓每層維持原有密度），需要重新裁決預算條款，且可能連動 `budgetCap` 的既有護欄語意——本輪選擇「總量不變、密度攤薄」是對契約卡「不讓層數在沒有屬性的情況下自行大於 1」之外沒有預算相關驗收標準的保守讀法。

## 實作備註

（實作期間與規格的偏差記錄於此，撰寫時留空。）
