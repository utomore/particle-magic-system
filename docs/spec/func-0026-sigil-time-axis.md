---
id: func-0026
type: spec
title: sigil-time-axis
description: 陣的獨立時間軸：駐留位移與畫完即凍結
status: open
created: 2026-08-19
updated: 2026-08-19
depends-on: [func-0002, func-0006, func-0014, func-0015, func-0016, func-0017, func-0020, func-0024]
related-adr: [adr-0014, adr-0015, adr-0020]
related-spec: []
---

# 陣的獨立時間軸 功能規格

> 依據：[subarch-0001](../arch/subarch-0001-magic-semantics.md) §功能規劃 階段四 #8 `sigil-linger-phase`、#9 `frozen-sigil`；記帳來源 [func-0017](func-0017-sigil-persistence.md) §8-1（靜止不重畫的陣）與 §8-3（陣的獨立時間軸）；ADR-0015（陣駐留到法術結束——本輪讓終點可位移）、ADR-0014 D3（`hashCircle` 交付即凍結）、ADR-0020（陣自轉的時鐘是施法秒數）

## 功能概述

func-0017 讓陣活到法術結束，但把終點**釘死**在 `ppEnd`，而且駐留期間陣以 `formLife` 為週期反覆重畫（「呼吸」）。這兩件事都是當時刻意的選擇，也都各自留了一筆記帳。本輪把它們變成**玩家可控的兩個旋鈕**，各自 opt-in、預設維持 0017 的行為。

兩個旋鈕都掛在一個新的陣層級 opt-in 鍵 `"sigil"` 底下：

| 鍵 | 型別 | 預設 | 語意 |
|---|---|---|---|
| `linger` | Number（秒） | `0` | 陣的終點相對法術終點的位移。正 = 法術收了陣還留著；負 = 陣比法術先收 |
| `hold` | Boolean | `false` | `true` = 畫完即凍結：陣畫上去之後外觀不再變化 |

**驗收標準**：

1. **零漣漪**：沒有 `"sigil"` 鍵的魔法陣，輸出**逐位元**與本輪交付前相同。7 張帶 `phases` 的出貨陣（`bare-sigil`／`comet-trail`／`grand-sigil`／`lattice-seal`／`soft-bloom`／`wuxing-seal`／`yin-yang`）一字不改、golden 不重錄。
2. **摘要不變**：`hashCircle` 對任何魔法陣的輸出不因 `"sigil"` 而改變——`linger`／`hold` 是時間與外觀，不是幾何，不得改變陣的長相（ADR-0014 D3）。
3. **linger 正向**：`linger > 0` 時 `spellLifetime`／`ppEnd` 隨之延長，`isFinished` 在陣真正消失後才翻，宿主不會拿到「法術已結束但畫面還有粒子」。
4. **linger 負向**：`linger < 0` 時陣提前收場，法術本體不受影響；且**陣至少活到畫完**（下界 `phDraw`），不論 `linger` 多負。
5. **hold 為真**：第一個 `formLife` 內陣仍沿索引序一點一點畫出（0016 的「索引序＝繪製序」不受影響），之後外觀恆定；陣仍然自轉（ADR-0020）。
6. **無 `phases` 時惰性**：`"sigil"` 有值但 `"phases"` 缺鍵時，沒有陣可計時，`"sigil"` 不產生任何效果，也不報錯。

## 相依性

（本節與 frontmatter 的 `depends-on` 由下方「使用到的既有串接介面」表反推，見文末一致性檢查。）

八份全部 `status: done`，**沒有任何進行中的相依**，因此本輪可立即動工：

| spec | 為什麼 |
|---|---|
| func-0002 | `compile`、`Envelope`、`ColorRamp`、`elementAppearance`、`firstBirth`／`particleAge` 的排程語意 |
| func-0006 | `Circle`／`PhaseConfig`／`emptyCircle`／`PhasePlan`／`castStartOf` 與 `phases` 的 codec；陣形發射器與 `formationAppearance` 都是這一輪的產物 |
| func-0014 | 不在介面表裡的**檔案格式相依**：`docs/spell-schema.md` 是 0014 的產物，而 `test/SchemaDocSpec.hs` 的單向律是「出貨範例用到的每個物件鍵都必須出現在該文件」。本輪新增鍵並新增用到它的範例陣，不更新文件測試就會紅 |
| func-0015 | `Appearance` 現在的五欄形狀（`appShape` 是 0015 加的）；`hold` 分支只換 `appColor`，其餘四欄逐欄照抄 |
| func-0016 | `hashCircle` 的凍結摘要。本輪對它的相依是**一條不變律**：`circleSigil` 不進摘要，`Magic.Sigil` 一行都不改 |
| func-0017 | `formEnvFor`／`formationEmittersFor` 現在的形狀（第二個 `Seconds` 參數＝陣的終點、無收束曲線）就是 0017 交付的；本輪只換那個參數的值 |
| func-0020 | `spinAngle` 吃**施法秒數**而非粒子年齡。這是驗收標準 5「凍結後陣仍自轉」成立的唯一依據 |
| func-0024 | `tools/Schema.hs` 的宣告表與 `docs/spell.schema.json` 的 golden 比對 |

**可否平行**：本輪改 `src/core/Magic/Circle.hs`、`src/core/Magic/Compile.hs`、`src/boundary/Magic/Codec.hs`、`tools/Schema.hs`。任何同時碰這四檔的 spec 必須與本輪串行；目前沒有進行中的 spec，故無衝突。

## 實作方式

### 1. 為什麼 `"sigil"` 是平輩鍵而不是 `phases.linger`

func-0017 §8-3 建議的是「例如 `phases.linger`」——是舉例不是裁決。查證後選了平輩鍵，三個理由：

1. **`PhaseConfig` 被位置式建構 46 次、散在 22 個檔案**（`PhaseConfig (Seconds 1.0) (Seconds 0.5)`），其中 20 個測試檔與 linger／hold 毫無關係。加欄位＝46 個機械遷移點。
2. **`PhaseConfig` 被雜湊進 `hashCircle`**：`hcPhaseConfig h (PhaseConfig d c) = hcSeconds (hcSeconds h d) c`。加欄位就必須手動把新欄位排除在雜湊之外，否則 7 張現有陣的圖案全部改掉——一個純粹的自找風險。
3. **`Circle` 幾乎都以 `emptyCircle { … }` 記錄更新建構**（183 處），所以加一個 `Circle` 欄位近乎免費。func-0025 的 `circleAnchors` 就是這個先例：第三個陣層級 opt-in 屬性，不是符文、不在槽位、`Nothing` 走舊路徑。

`circleSigil` 是第四個，形狀照抄前三個（`phases`／`fields`／`anchors`）：JSON 平輩鍵 ↔ `Circle` 的一個 `Maybe` 欄位，一對一，往返律 trivial。

### 2. 為什麼 `circleSigil` 不進 `hashCircle`

`hcCircle` 目前雜湊 `outerRings`／`interLayer`／`innerRings`／`core`／`circlePhases`,**不雜湊 `circleFields` 也不雜湊 `circleAnchors`**。原始碼註解寫明了原則：

> hanging a gravity well on a spell silently redraws its sigil — a visible break of that law. So fields ride alongside here exactly as they do through `Magic.Compile.compile`: carried, never folded.

`circleSigil` 正是「carried, never folded」那一類：它改的是陣**存在多久**與**怎麼收尾**，不是陣**長什麼樣**。所以 `Magic.Sigil.hs` 本輪**一行都不改**，也不需要新的建構子 tag（`tagW h4 5` 仍是最後一個）。這是驗收標準 2 的實作依據，也是它最便宜的實作：不做事。

### 3. frozen-sigil：翻掉 func-0017 §8-1 的成本判斷

0017 §8-1 把它記成「需要『畫完即凍結』的**新排程語意**，不是調參數」，理由是「要真正靜止需把 `envLifetime` 拉到整場，會讓出生時刻攤到整場，直接違反 0016 的索引序＝繪製序」。

**那個理由只在「位置也吃 age」的前提下成立，而陣形粒子的位置不吃 age。** 逐層追 `positionIn`（`rawPosition = spawnW + trajTerm + vscale age (spreadDrift + nodeDriftW)`）：

| 項 | 陣形發射器的值 | 隨 age 變？ |
|---|---|---|
| `spawnW` | `rotate2 (spinAngle (skSpin stroke) tCast) (sampleStroke stroke i)` | 否——自轉吃施法時鐘 `tCast`（ADR-0020；原始碼註解：「Driving it by age would smear the sigil into a spiral instead of turning it」） |
| `trajTerm` | `motTraject = Forward 0` ⇒ `trajectoryOffset` 回 `(0 * age, V2 0 0)` | 否，恆零向量 |
| `spreadDrift` | `SpawnOnStroke` ⇒ `V3 0 0 0`；節點／中心的 `SpawnAtAnchor 0` ⇒ spread 0 | 否 |
| `nodeDriftW` | `motDrift = V3 0 0 0` | 否 |
| `motRange`／`motConverge` | 皆 `Nothing`（收束已由 0017 取消） | 否 |
| `appAmplify` | `Nothing` | 否 |

**唯一隨 age 變的是那條淡出的 ramp**：`formationAppearance` 回 `ColorRamp start (clearAlpha start)`，而 `ColorRamp` 的語意是「life 分數 0..1 線性內插」。所謂「呼吸」＝一道沿索引跑的亮度波，每 `formLife` 重來一次。

於是：**把陣形的 ramp 改成不淡出（`rampEnd = rampStart`），重生循環就變成不可觀測的**。粒子仍每 `formLife` 重生一次，但外觀完全相同。而 `firstBirth env n i = envDelay + (i/n)·envLifetime` **原封不動**，所以第一個 `formLife` 仍是沿索引序逐點畫出——這正是「畫完即凍結」的字面意思，0016 的索引序＝繪製序毫髮無傷。

實作因此縮成一個查表分支：

```haskell
formationAppearance :: Bool -> Element -> Appearance
formationAppearance hold element =
  let Appearance (ColorRamp start _) _ blend _ _ = elementAppearance element
      end = if hold then start else clearAlpha start
   in Appearance (ColorRamp start end) 0.03 blend Nothing BillboardSquare
```

`formationAppearance` **未被匯出**（`Magic.Compile` 的匯出清單沒有它，全 repo 零外部引用），所以加參數不動任何對外簽名。

**收場行為（已裁決保留）**：生成窗在「陣的終點 − `formLife`」關閉，之後每顆粒子在自己的循環邊界上消失，順序就是索引序。淡出的 ramp 讓這讀起來是「淡出」；不淡出的 ramp 會讓它讀起來是**沿當初畫上去的順序被擦掉**。這與「畫上去」對稱，且零程式碼，故保留為 `hold` 的收場語意。

### 4. sigil-linger-phase：終點位移與 `ppEnd` 的連動

`compile` 現在算出兩個終點：

```haskell
-- 既有：法術本體的終點（最後一顆施放粒子死盡）
spellEnd = Seconds (delay + duration + lifetime)

-- 本輪新增：陣的終點
sigilEnd = case mPhases of
  Nothing -> spellEnd                                   -- 無陣，linger 無意義（驗收 6）
  Just pc -> Seconds (max drawEndD (spellEndD + lingerD))
    where drawEndD = unSeconds (phDraw pc)              -- 下界：至少活到畫完（驗收 4）

formationEmitters = case mPhases of
  Nothing -> []
  Just _  -> formationEmittersFor circle castStart sigilEnd element   -- 換掉第三參數

plan = PhasePlan
  { ppDrawEnd     = maybe (Seconds 0) phDraw mPhases    -- 不變
  , ppConvergeEnd = castStart                           -- 不變
  , ppCastingEnd  = Seconds (delay + duration)          -- 不變（法術本體的生成窗）
  , ppEnd         = Seconds (max spellEndD sigilEndD)    -- 本輪：兩者取 max
  }
```

`spellLifetime = ppEnd plan` 的既有寫法不動，所以 `PhasePlan` 的不變量「`ppEnd` 與 `spellLifetime` 永遠一致」自動維持，`isFinished` 也自動跟著對（驗收 3）。

`linger = 0` 時 `sigilEnd == spellEnd`、`ppEnd` 取 max 後仍是 `spellEnd`，**整條運算式退化成交付前的原式**——這是零漣漪律（驗收 1）在建構上成立的原因，不是靠測試碰巧通過。

**為什麼負值用 clamp 而不是報錯**：`CompileError` 目前只有一個建構子 `BudgetExceeded !Int !Int`，而它經 C ABI 映射成錯誤碼（`PM_ERR_JSON`／`PM_ERR_BUDGET`）。加一個建構子會連動 `include/particle_magic.h`（只加不改，但要動）、`bindings/csharp/ParticleMagic.cs` 與 `test/BindingContractSpec.hs`——為了「linger 太負」這件事付這條漣漪不值得。改為：**codec 管值域、compile 管下界**。

- **codec**：`-maxLinger <= linger <= maxLinger`（`maxLinger = 60` 秒），超出回 `JsonError` 附路徑。上界是必要的——沒有上界，一個離譜的 `linger` 會讓 `ppEnd` 大到 `isFinished` 實質永不為真，宿主就掛在那裡。這個 cap 的形狀照 func-0025 的 `maxAnchors = 16` 先例。
- **compile**：`max drawEndD` 保證「陣至少活到畫完」在建構上成立，不論 codec 放進來什麼。

### 5. Codec

```haskell
parseSigilTiming :: Value -> Parser SigilTiming
parseSigilTiming = withObject "sigil" $ \o -> do
  linger <- o .:? "linger" .!= 0 >>= boundedLinger "linger"
  hold   <- o .:? "hold"   .!= False
  pure (SigilTiming (Seconds linger) hold)
```

`parseCircle` 加一行 `sigil <- parseSlot "sigil" parseSigilTiming o`，`Circle` 建構加 `circleSigil = sigil`。`slotValue` 既有語意讓 `"sigil": null` ≡ 無鍵，與 `phases`／`fields`／`anchors` 一致。

**兩個鍵都選配、`"sigil": {}` 合法且是 no-op。** 這裡刻意**不**照 `parseAnchors` 拒收 `[]` 的做法：0025 拒收空陣列是因為 `Just []` 有一個**不同且意外**的語意（沒有施放發射器），會與「無鍵」撞車；而 `Just (SigilTiming 0 False)` 與 `Nothing` 行為**完全相同**，沒有要防的撞車，多一條驗證規則只是多一個要記的例外。

`encodeCircle` 加一列 `"sigil" .= maybe Null encodeSigilTiming (circleSigil circle)`——用 `Null` 而非 `{}` 表示缺席，理由與 `anchors` 那列相同：寫出去的檔要讀得回來，而 `Null` ≡ 無鍵是既有語意。

### 6. 作者面

- `tools/Schema.hs`：新增 `sigilDef`，並在 circle 的 `properties` 加 `("sigil", nullable (ref "sigil"))`，位置排在 `anchors` 之後。
- `docs/spell.schema.json`：以 `cabal run magic-schema -- --out docs/spell.schema.json` 重生成（`--check` 是 golden 比對，所以必須重生成而非手改）。
- `docs/spell-schema.md`：§8 的標題由「選配：`phases`、`fields` 與 `anchors`」改為含 `sigil`，並新增 §8.4。
- 新示範陣 `assets/spells/lingering-seal.json`：同時用上 `linger` 與 `hold`，讓 `test/ValidateSpec.hs` 的「所有出貨範例都載入、編譯、施放」自動涵蓋它，也讓 `SchemaDocSpec` 的單向律強制文件更新。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源 spec | 用途 |
|---|---|---|---|
| `data Circle = Circle { outerRings :: TwoOf (Maybe OuterRune), interLayer :: Maybe BridgeRune, innerRings :: TwoOf (Maybe InnerRune), core :: Core, circlePhases :: !(Maybe PhaseConfig), circleFields :: ![ForceField], circleAnchors :: !(Maybe [Anchor]) }` | `src/core/Magic/Circle.hs` | func-0006 | 加第四個陣層級欄位 `circleSigil` |
| `data PhaseConfig = PhaseConfig { phDraw :: !Seconds, phConverge :: !Seconds }` | `src/core/Magic/Circle.hs` | func-0006 | 讀 `phDraw` 當 `sigilEnd` 的下界；**本輪不加欄位** |
| `emptyCircle :: Circle` | `src/core/Magic/Circle.hs` | func-0006 | 新欄位的預設 `Nothing` |
| `data Envelope = Envelope { envDelay :: !Seconds, envDuration :: !Seconds, envLifetime :: !Seconds }` | `src/core/Magic/Rune.hs` | func-0002 | `formEnvFor` 的產物；`envDuration` 是 linger 實際改到的量 |
| `formEnvFor :: Seconds -> Seconds -> Envelope` | `src/core/Magic/Compile.hs` | func-0017 | 第二參數由 `spellEnd` 換成 `sigilEnd`；函式本體不改 |
| `formationEmittersFor :: Circle -> Seconds -> Seconds -> Element -> [EmitterSpec]` | `src/core/Magic/Compile.hs` | func-0017 | 第三參數傳 `sigilEnd`；內部由已在作用域的 `circle` 讀 `circleSigil` 取 `hold`，簽名不變 |
| `formationAppearance :: Element -> Appearance` | `src/core/Magic/Compile.hs` | func-0006 | 加 `Bool`（hold）參數；未匯出，全 repo 零外部引用 |
| `elementAppearance :: Element -> Appearance` | `src/core/Magic/Compile.hs` | func-0002 | 取元素的起始色當 ramp 兩端 |
| `data Appearance = Appearance { appColor :: !ColorRamp, appSize :: !Float, appBlend :: !BlendMode, appAmplify :: !(Maybe Expr), appShape :: !BillboardShape }` | `src/core/Magic/Compile.hs` | func-0015 | `hold` 分支只換 `appColor`，其餘四欄照抄 |
| `data ColorRamp = ColorRamp { rampStart :: !Word32, rampEnd :: !Word32 }` | `src/core/Magic/Compile.hs` | func-0002 | `hold` ⇒ `rampEnd = rampStart` |
| `data PhasePlan = PhasePlan { ppDrawEnd :: !Seconds, ppConvergeEnd :: !Seconds, ppCastingEnd :: !Seconds, ppEnd :: !Seconds }` | `src/core/Magic/Compile.hs` | func-0006 | `ppEnd` 改為 `max spellEnd sigilEnd`，其餘三個界標不動 |
| `compile :: Circle -> Either CompileError CompiledSpell` | `src/core/Magic/Compile.hs` | func-0002 | 本輪唯一的語意修改點 |
| `castStartOf :: Maybe PhaseConfig -> Seconds` | `src/core/Magic/Compile.hs` | func-0006 | 不改；`castStart` 照舊 |
| `firstBirth :: Envelope -> Int -> Int -> Double` | `src/core/Magic/Particle/Analytic.hs` | func-0002 | **不改**；它是「索引序＝繪製序」的來源，本輪必須保它逐位元不變 |
| `particleAge :: Envelope -> Int -> Int -> Time -> Maybe Double` | `src/core/Magic/Particle/Analytic.hs` | func-0002 | **不改**；重生循環與收場的逐點消失都由它產生 |
| `spinAngle :: SigilSpin -> Double -> Float` | `src/core/Magic/Sigil.hs` | func-0020 | **不改**；第二參數是施法秒數而非粒子年齡，這是「凍結後陣仍自轉」的唯一依據 |
| `hashCircle :: Circle -> Word64` | `src/core/Magic/Sigil.hs` | func-0016 | **不改**；`circleSigil` 不進摘要（ADR-0014 D3） |
| `parsePhaseConfig :: Value -> Parser PhaseConfig` | `src/boundary/Magic/Codec.hs` | func-0006 | 不改；`parseSigilTiming` 照它的形狀寫 |
| `encodePhaseConfig :: PhaseConfig -> Value` | `src/boundary/Magic/Codec.hs` | func-0006 | 不改；`encodeSigilTiming` 照它的形狀寫 |
| `parseSlot :: AK.Key -> (Value -> Parser a) -> Object -> Parser (Maybe a)` | `src/boundary/Magic/Codec.hs` | - | 掛上 `"sigil"` 這個 opt-in 鍵 |
| `slotValue :: Object -> AK.Key -> Parser (Maybe Value)` | `src/boundary/Magic/Codec.hs` | - | `"sigil": null` ≡ 無鍵 的來源 |
| `nonNegative :: String -> Double -> Parser Double` | `src/boundary/Magic/Codec.hs` | - | `boundedLinger` 的形狀範本（linger 可為負，故不能直接沿用） |
| `phasesDef :: J` | `tools/Schema.hs` | func-0024 | `sigilDef` 照它的形狀寫 |

## 新增的介面

```haskell
-- src/core/Magic/Circle.hs（新增，並加入匯出清單）

-- | 陣自己的時間軸（func-spec 0026）。第四個陣層級屬性，慣例同
-- 'circlePhases'／'circleFields'／'circleAnchors'：不是符文、不在槽位、
-- opt-in，且 'Nothing'（'emptyCircle' 的值）走 0017 交付的舊路徑——
-- 陣與法術同時收場、駐留期間以 formLife 為週期重畫。
--
-- 刻意不進 'Magic.Sigil.hashCircle'：本型別改的是陣存在多久與怎麼收尾，
-- 不是陣長什麼樣（ADR-0014 D3）。
data SigilTiming = SigilTiming
  { stLinger :: !Seconds
  -- ^ 陣的終點相對法術終點的位移。0 = 同時收場。正 = 陣留得比法術久
  -- （'ppEnd' 隨之延長）。負 = 陣先收，下界為 'phDraw'：不論多負，
  -- 陣至少活到畫完。
  , stHold :: !Bool
  -- ^ 'True' = 畫完即凍結。第一個 formLife 仍沿索引序逐點畫出，之後
  -- 外觀恆定（陣仍自轉——那吃施法時鐘，不吃粒子年齡）。
  }
  deriving (Eq, Show)

-- Circle 加一欄
--   , circleSigil :: !(Maybe SigilTiming)

-- src/boundary/Magic/Codec.hs（新增，皆為模組內部）
parseSigilTiming  :: Value -> Parser SigilTiming
encodeSigilTiming :: SigilTiming -> Value
boundedLinger     :: String -> Double -> Parser Double   -- |x| <= maxLinger
maxLinger         :: Double                              -- 60

-- src/core/Magic/Compile.hs（既有函式改簽名，未匯出）
formationAppearance :: Bool -> Element -> Appearance

-- tools/Schema.hs（新增）
sigilDef :: J
```

## TodoList

- [ ] T1: `Magic.Circle` 加 `SigilTiming` 型別與 `Circle.circleSigil` 欄位，`emptyCircle` 補 `Nothing`，加入匯出清單  `dep: -`
- [ ] T2: `Magic.Codec` 加 `parseSigilTiming`／`encodeSigilTiming`／`boundedLinger`／`maxLinger`，接上 `parseCircle` 與 `encodeCircle`  `dep: T1`
- [ ] T3: `Magic.Compile` 算 `sigilEnd`（含 `phDraw` 下界與無 `phases` 惰性），傳給 `formationEmittersFor`，`ppEnd` 改為 `max spellEnd sigilEnd`  `dep: T1`
- [ ] T4: `formationAppearance` 加 `hold` 參數，`formationEmittersFor` 由 `circleSigil` 取值傳入  `dep: T1`
- [ ] T5: 零漣漪與摘要不變的迴歸守護：`hashCircle` 不因 `circleSigil` 改變，7 張帶 `phases` 的出貨陣逐位元不變  `dep: T3, T4`
- [ ] T6: 作者面：`tools/Schema.hs` 的 `sigilDef`、重生成 `docs/spell.schema.json`、`docs/spell-schema.md` §8 標題與新的 §8.4  `dep: T2`
- [ ] T7: 新示範陣 `assets/spells/lingering-seal.json`（同時用 `linger` 與 `hold`），並以 demo 視窗做一次手動 smoke  `dep: T3, T4, T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test/SigilTimingSpec.hs` | `SigilTiming` 的 `Eq`／`Show`；`circleSigil emptyCircle == Nothing`；`Circle` 的記錄更新不影響其他三個陣層級欄位 |
| T2 | `test/SigilTimingCodecSpec.hs` | 往返律 `loadCircle . saveCircle ≡ id`；`"sigil": null` ≡ 無鍵；`"sigil": {}` ≡ `SigilTiming 0 False`；`linger` 超出 ±`maxLinger` 回 `JsonError` 且訊息含鍵路徑；`hold` 非布林被拒 |
| T3 | `test/SigilLingerSpec.hs` | `linger > 0` ⇒ `ppEnd == spellLifetime` 且等於 `spellEnd + linger`，`isFinished` 在該時刻後才真；`linger < 0` ⇒ 陣的生成窗提前關、法術本體的 `ppCastingEnd` 不變；極負 `linger` 被 clamp 到 `phDraw`；`circlePhases = Nothing` 時任何 `linger` 皆無效果 |
| T4 | `test/SigilHoldSpec.hs` | `hold` ⇒ 陣形 batch 的 `rampStart == rampEnd`；`t < formLife` 時存活的陣形粒子數隨 `t` 單調增（仍在逐點畫出）；`t > formLife` 後同一顆粒子的顏色跨重生邊界不變；同一份陣在 `hold` 開關兩態下位置逐位元相同（位置與 age 無關的迴歸鎖） |
| T5 | `test/SigilTimingInvariantSpec.hs` | `hashCircle c == hashCircle c { circleSigil = Just (SigilTiming (Seconds 2) True) }`；7 張帶 `phases` 的出貨陣在交付前後 240 幀輸出逐位元相同；`Just (SigilTiming 0 False)` 與 `Nothing` 的輸出逐位元相同 |
| T6 | `test/JsonSchemaSpec.hs`、`test/SchemaDocSpec.hs`（擴充） | `docs/spell.schema.json` 與 `generateSchema` 一致且含 `sigil`；`sigil`／`linger`／`hold` 三個鍵都出現在 `docs/spell-schema.md` |
| T7 | `test/ValidateSpec.hs`（既有律自動涵蓋）＋ `test/InspectSpec.hs`（擴充） | `lingering-seal.json` 載入、編譯、施放皆成功；`magic-inspect` 報告的生命週期界標反映延長後的 `ppEnd` |

## 實作備註

（實作期間與規格的偏差記錄於此。）
