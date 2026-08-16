---
id: adr-0018
type: adr
title: custom-shader-and-columns
description: 自訂 shader 進殼層、SoA 加速度欄以加法鬆綁
status: accepted
created: 2026-08-16
updated: 2026-08-16
related-adr: [adr-0006, adr-0009, adr-0011, adr-0013]
related-spec: [func-0023]
---

# ADR-0018：自訂 shader 落在殼層、SoA 欄位佈局以「加欄」鬆綁

- 狀態：已採納（2026-08-16）
- 相關：[func-spec 0023](../spec/func-0023-production-visuals.md)（本輪交付）、[ADR-0009](adr-0009-dynamic-quad-mesh-rendering.md)（**其「不自訂 shader」前提被本 ADR 取代；繪製路徑保留**）、[ADR-0006](adr-0006-soa-unboxed-buffer.md)（其六欄硬點被本 ADR 鬆綁為九欄）、[ADR-0013](adr-0013-billboard-vocabulary.md) D1（其否決理由被本輪的速度欄消解）、[ADR-0011](adr-0011-ffi-c-abi-boundary.md) D7（only-add 規則的第二次實戰）

## 背景

roadmap 維度 C（產品級特效系統）停在 50%：0013 讓畫面「看得清楚」，0015 讓人「看得出是什麼」，但拖尾、軟粒子、後處理三樣都沒有。三樣都撞到同兩道牆：

1. **ADR-0009 的「不自訂 shader」**。那條決定是 instancing 被否決時順帶下的——預設 shader 已經能乘進頂點色與 diffuse 貼圖，逐粒子顏色不需要自訂 shader，所以「零 shader 維護成本」被當成正面後果寫進去。但軟粒子要取樣深度、bloom 要三道全螢幕 pass，兩者**在定義上**就是 shader 工作。
2. **ADR-0006 的六欄佈局硬點**（architecture §11 第 3 列）。拖尾要知道粒子往哪走、走多快，而緩衝裡沒有速度。0015 §8-1 因此明文把「真拖尾」列為不做，理由正確：當時要它就得動 `pm_observe` 的六欄簽名。

第三道牆是 0015 記在 ADR-0013 D1 的：拉伸倍率看起來是 per-batch 參數，而 `PM_BATCH_INFO_STRIDE` 凍結為 4，沒有第五個 int 可放。

## 決策

### D1：ADR-0009 的「不自訂 shader」前提被取代；其繪製路徑保留

自訂 shader 可以用，**但只在殼層**。GLSL 住 `assets/shaders/`，由 `App.Render.Shader`（純宣告）與 `App.Render.Raylib3D`（唯一碰 h-raylib 的模組）載入。

**ADR-0009 保護的東西不是「沒有 shader」，是「渲染細節不進庫」**——後者一字不動：動態 quad mesh、`c'` 指標 API、draw call 數不隨粒子數成長，全部保留；`FrameOutput`／`RenderBatch`／`ParticleBuffer` 仍零 raylib 依賴（architecture §5.2）。差別只是材質上綁的是我們的 program 而不是預設 program。

「零 shader 維護成本」這條正面後果**確實被放棄了**，換到的是 roadmap 維度 C 剩下的那一半。這是一次有代價的交換，不是免費的。

### D2：SoA 欄位佈局以「加欄＋新查詢函數」鬆綁，不改既有簽名

`ParticleBuffer` 由六欄變九欄（加 `pbVelX/Y/Z`）。architecture §11 把這裡列為硬點，理由是「欄位被熱路徑、FFI 傳遞、渲染後端三方依賴」。本輪逐處付帳，方式一律是**加新的、不動舊的**：

| 依賴方 | 作法 |
|---|---|
| 熱路徑 | **opt-in**：無 `BillboardTrail` 的魔法速度欄為空向量，`sample` 結構性選 `buildBuffer` 而非 `buildBufferWithVelocity`，逐粒子迴圈一條指令都不多（比照 ADR-0010 D9 的零場快路徑） |
| FFI | 新增 `pm_observe_ex`；`pm_observe` 一字不動，實作上降級為「速度指標為 NULL 的 `pm_observe_ex`」 |
| 邊界層 | 新增 `fromColumnsWithVelocity`；`fromColumns` 簽名不變 |
| 渲染後端 | 只有 trail batch 讀速度；其餘走既有展開 |

**opt-in 是型別附近的不變量而不是散在各處的 `if`**：`bufferInvariant` 多一條——每個速度欄的長度要嘛 0、要嘛 `pbCount`，且三欄同步。消費者只要問一次 `hasVelocity`。

九欄佈局交付即凍結。**這不是「以後加欄變便宜了」**：每一欄都要重付上表三處代價，而下一輪不會剛好又有一個「本來就要加的欄位」把另一個問題順帶解掉。

### D3：ADR-0013 D1 的否決理由消失，而它保護的東西沒有被動

0015 想要帶參數的拉伸 billboard，被 `PM_BATCH_INFO_STRIDE` 擋下。本輪**繞開了整個問題**：拖尾的方向與長度是**逐粒子**的，來自那顆粒子自己的速度——它從來就不是 per-batch 參數。所以：

- `BillboardTrail` 是**無參數**建構子，完全符合 0015 凍結的「`BillboardShape` 永遠無參數」；
- `PM_BATCH_INFO_STRIDE` 保持 4；
- 拉伸資訊走**本來就要加的**速度欄，沒有第二個機制。

這條值得記下來，因為它同時解釋了**為什麼 0015 當時不做是對的**：當時速度欄不存在，唯一的實作路徑真的要動 wire 佈局。等對的資料到位，原本擋路的約束就不再是約束。

### D4：速度以固定步長有限差分定義，不做符號微分

```text
analyticVel(i) = (particlePosition(age) − particlePosition(age − h)) / h,  h = 1/240（凍結）
renderedVel(i) = analyticVel(i) + 力場層該槽位的 ssVel
```

三個要點：

1. **`h` 是常數不是 `dt`**。用 `dt` 的話同一個法術在 30 fps 與 144 fps 下拖尾長度不同，違反決定論（ADR-0007）與固定時步公理（architecture §11）。
2. **`age − h < 0` 時**把較早的取樣點夾到 0、除以實際區間；`age = 0` 回傳零。負年齡永遠不進取樣器。
3. **力場那一半是精確的差分而非近似**：`stepSlot` 積分的是 `disp' = disp + dt·vel'`，所以 `(disp' − disp)/dt == vel'` 恆等。位移只以積分歷史存在、不是年齡的函數，`renderedPos(age − h)` 沒有閉式可差分——這是規格 §2.4 單一公式寫法在實作上的偏差，記在 func-spec 0023 §10。

符號微分被否決：`FormulaRune` 是玩家寫的 `Expr`，要新增一整個遍歷並回答 `Chan`（不可微）與 `floor`／`sign`（不連續），收益只是省一次取樣。

### D5：跨 batch 深度交錯要靠**單次繪製**，因此貼圖併成 atlas

0015 之後一個法術可能產出多個 batch，各自排序。兩個 alpha batch 因此依 **batch 順序**合成，與深度無關：遠處的拖尾會蓋住近處的光點。

func-spec 0023 §2.7 原本提的作法是「併排 → 一次排序 → 依 (batch, 原索引) 拆回各 batch 的 permutation」。**那個作法達不到它自己的驗收律**：batch 仍然是連續繪製的，所以畫面仍然是「batch 0 全部、然後 batch 1 全部」，不管每個 batch 內部怎麼排。（規格 §6 指定的 property「全體 alpha 粒子深度非遞增」在實作時直接抓到這點。）

真正兌現只能靠**把全體 alpha 粒子畫成一次 draw**，而擋住這件事的是「每個 batch 綁自己的貼圖」。因此：**四種形態的程序生成貼圖併成一張 atlas**，形態改由每個 quad 的 texcoord 攜帶。於是：

- 沒有 per-batch 貼圖綁定了 ⇒ 沒有東西強迫 draw call 邊界 ⇒ 全體 alpha 可以一起排序、一起畫；
- **draw call 數反而變少**：一幀最多兩次（alpha 一次、additive 一次），不論有幾個 batch。ADR-0009 的「draw call 數 = batch 數而非粒子數」不但成立，還更寬裕；
- 代價：`quadTexcoords` 由「開機寫一次」變成**每幀上傳**（每次 draw 多一次 `updateMeshBuffer`），換掉每個 shape 一次 draw call。

additive batch 也併成一次，但**不排序**：加法可交換，順序不是畫面。

## 後果

**正面**：

- roadmap 維度 C 的另一半交付：拖尾、bloom、軟粒子、跨批交錯。
- 既有宿主逐位元零受擾：15 個既有範例陣的六欄輸出 240 幀不變，`pm_observe` 一字不動，C／C# 宿主不需重編譯。
- 每幀 draw call 由「batch 數」降為「最多 2」。
- 「加欄」有了可重複的範本（D2 那張表），日後真的必須再加欄時有路可走。

**負面**：

- **shader 維護成本從零變成五份 GLSL**。它們不在編譯器的守備範圍內：一個 shader 拼錯 uniform 名不會壞掉，只會畫錯。`test/ShaderPipelineSpec.hs` 把「每個 pass 設的 uniform 都要在 GLSL 裡宣告」變成測試，但那只擋得住名字，擋不住數學。
- **h-raylib 的 `DrawMesh` 只綁材質 map 槽**：用 `SetShaderValueTexture` 設的 sampler 在 mesh 繪製時根本沒被綁上。深度貼圖因此必須走材質的第二個 map 槽（`texture1`）。這一條沒有任何測試抓得到——它是手動 smoke 抓到的（func-spec 0023 §9）。
- **軟粒子要一次額外的深度 pre-pass**：不能取樣正在寫入的那張 render texture 的深度附件（結果未定義，實測是所有粒子消失），視窗自己的深度緩衝又不可取樣。所以場景幾何畫兩次。四個方塊，可接受；真實場景就不是了。
- 九欄凍結：`ParticleBuffer` 的 `Show`／`Eq`／`NFData` 與所有 record 建構點都多三欄。
- LDR bloom：真 HDR 要換整條 RenderTexture 格式與色彩管理（func-spec 0023 §8-5，另輪）。

## 被否決的替代方案

- **符號微分求速度**——D4。
- **帶參數的 `BillboardShape`**（動 stride 或開旁路查詢）——D3 讓需求消失了，ADR-0013 D1 的兩個備案都不必動用。
- **真正的歷史軌跡拖尾（ribbon）**：保存前 N 幀位置。需要跨幀狀態，而系統目前唯一的跨幀狀態是 `FieldState`。速度拉伸是解析式模型下的正確作法；ribbon 屬於另一種模型（func-spec 0023 §8-3）。
- **shader 由玩家在 JSON 裡寫**：會把 GPU API 帶進輸入合約，直接破壞 ADR-0005 的可攜性與「渲染細節不進庫」。**永久非目標**。
- **跨 batch 交錯改用 run 切段繪製**（全域排序後切成同 batch 的連續段，一段一個 draw call）：順序正確，改動最小，但兩個 alpha batch 完全交錯時 draw call 數退化到接近粒子數——直接打破 ADR-0009 的核心承諾。使用者裁決 2026-08-16 選 atlas。
- **只把同 shape 的 alpha batch 合併、群組間再排序**：draw call 有上界（≤ shape 數），但跨 shape 只到群組粒度——而規格舉的例子（alpha 拖尾 vs alpha 光點）正好是跨 shape 的，等於沒解決。同上裁決否決。
- **粒子畫成獨立圖層再合成**：可避免深度 pre-pass，但 additive 粒子疊在場景上的結果會錯（alpha 合成一個圖層無法重現逐片段的加法）。
