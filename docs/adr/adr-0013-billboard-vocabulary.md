---
id: adr-0013
type: adr
title: billboard-vocabulary
status: accepted
created: 2026-08-15
updated: 2026-08-15
related-adr: [adr-0003, adr-0009, adr-0011]
related-spec: [func-0015]
---

# ADR-0013：告示板詞彙——無參數列舉、型別落點遷移、程序生成貼圖

- 狀態：已採納（2026-08-15）
- 相關：[architecture.md §1.2、§5.2、§10](../architecture.md)；ADR-0003（外圈＝展現）、ADR-0009（動態 quad mesh、不自訂 shader）、ADR-0011 D7（header 只加不改）；落地 spec：0015

## 背景

架構書 §1.2 說「看到的粒子形態**就是**魔法的語意」，但 0015 之前粒子形態的值域大小是 1（`BillboardSquare`）。要讓「展現」成為玩家可寫進魔法陣的真詞彙，必須回答三個結構問題：

1. **shape 可以帶參數嗎？** `batch_info` 的四欄佈局（`offset/count/blend/shape`）與 `PM_BATCH_INFO_STRIDE 4` 已被 0009 凍結——shape 在 C 線格式上永遠只有一個 int 的空間。
2. **`BillboardShape` 該定義在哪？** 它一直住在邊界層 `Magic.Interface`（渲染輸出的一部分），但 `StyleRune BillboardShape` 讓它成為符文參數——核心型別（`Magic.Rune`）的一員。
3. **差異化的像素從哪來？** ADR-0009 否決了自訂 shader；引入美術資產則會把資產路徑寫進宿主整合合約。

## 決策

**D1（`BillboardShape` 永遠是無參數列舉）** 四個建構子 `BillboardSquare | BillboardSoftDot | BillboardRing | BillboardSpark`，derive `Enum`/`Bounded`；**宣告序即 C 線碼**（`shapeCode = fromEnum`），`PM_SHAPE_SQUARE = 0` 永久釘選，新 shape 只能**加在清單末端**（鏡射測試遍歷 `[minBound .. maxBound]` 雙向對照 header，中插會先撞上 SQUARE = 0 的釘選斷言）。帶參數的 shape（拉伸倍率、旋轉角、逐粒子朝向）被否決：那需要改凍結的 stride（破壞性變更），或另開旁路查詢（`pm_max_particles` 模式的 `pm_batch_shape_params`）。v1 沒有任何需求證明值得付這個成本；需求出現時走旁路查詢案，stride 仍不動。

**D2（型別落點遷移規則）** 一個型別成為符文參數的那一刻，它就該搬進核心的詞彙模組（`Magic.Rune`），由原模組改為 re-export——**宿主可見面一字不變**（`Magic.Interface` 的匯出清單文本仍是 `BillboardShape (..)`）。這是可重複的規則，不是一次性搬家：先例是 architecture §4.7 對 `CastContext` 落點的註記。

**D3（差異化 = 程序生成貼圖走預設 shader 的 diffuse map）** ADR-0009 否決的是 instancing 與自訂 shader，**不是貼圖**：預設材質本來就有 1×1 白貼圖，mesh 本來就有（全零的）texcoord VBO。0015 只是把 texcoord 填上值（開機一次，capacity 的純函數）、開機把三張 64×64 程序生成 RGBA（`spriteTexels`，純函數、可測）上傳成 texture，逐 batch 綁進 diffuse 槽。RGB 恆 255、資訊全在 alpha——頂點色仍是唯一的顏色來源，`ColorRamp` 的語意不被貼圖搶走。`BillboardSquare` 不綁自己的貼圖，直接用預設白貼圖 ⇒ 既有畫面逐位元不變。**零外部資產**：宿主整合面不出現任何檔案路徑。

**D4（陣形永遠是方塊）** `StyleRune` 只作用於施放主體；陣形發射器（畫陣的線）固定 `BillboardSquare`——魔法陣是畫出來的線，硬邊點才銳利。這也讓帶 `StyleRune` 的陣天然成為複數 batch 的第一個真實來源（Drawing 期：主效果一批＋陣形一批）。

**D5（分批 = 相鄰 run-length，不做 group-by）** `observeSpell` 依相鄰發射器的 `(blend, shape)` 分批：buffer 列序＝發射器串接序（0010），所以 run 就是連續切片（`U.slice` 零拷貝），分割律（批次串接 ≡ 分批前 buffer 逐位元）結構性成立。相同鍵不相鄰**刻意不合併**——合併需重排列，會破壞逐位元相容與 `aliveSlots` 對齊。發射器數是個位數，批次數的代價可忽略。

## 被否決的方案

- **帶參數的 `BillboardShape`**（動 stride 或開旁路查詢）——見 D1；需求出現前不付合約成本。
- **自訂 shader / SDF 著色**——直接違反 ADR-0009 前提；要走這條路必先修 ADR。
- **外部貼圖資產 / sprite atlas / 作者自指貼圖**——把資產管線帶進宿主整合合約，0015 §8 明列非目標。
- **group-by 合併同鍵批次**——破壞分割律的逐位元性（見 D5）。

## 後果

**正面**：
- 展現詞彙端到端貫通（符文 → 核心 → C ABI → 渲染），且全程純增補：header 只加三個 `#define`，C# 綁定由既有鏡射測試強制跟上。
- 線碼由 `Enum` 派生「是定義而非慣例」，擴充詞彙的成本降到「在清單末端加一個建構子＋一張貼圖」。
- 既有 10 個範例陣 `FrameOutput` 逐位元不變（opt-in 律），golden 網（PerfGoldenSpec）零重錄。

**負面／記帳**：
- shape 的表現力被一個 int 封頂；參數化需求（拉伸、旋轉、真拖尾）已在 roadmap 維度 C 記帳。
- 批次數可能多於相異鍵數（不相鄰同鍵不合併）；draw call 仍與粒子數無關，預算不變。
