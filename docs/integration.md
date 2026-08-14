# 宿主整合指南

> 版本：1.0（2026-08-14，對應 spec 0009 交付的 C ABI 第 1 代、ABI version 1）
> 對象：想把這套粒子魔法系統接進自己遊戲的人——Unity、Godot、C/C++ 引擎、Haskell 專案，或完全自製的前端。
> 相關文件：[architecture.md](architecture.md)（系統設計）、[roadmap.md](roadmap.md)（還缺什麼）、[`include/particle_magic.h`](../include/particle_magic.h)（凍結的 C 合約）

---

## 0. 一句話心智模型

> **JSON 進，六條陣列出。這個庫一行畫圖的程式碼都沒有，也永遠不會有。**

你給它一張魔法陣（JSON 文字）、施法者的位置與面向、一個亂數種子，然後每幀給它一個 `dt`；它回你一批粒子的 **SoA（Structure of Arrays）**——六條等長陣列（x、y、z、size、life、color），外加「哪一段屬於哪個批次、該用什麼混合模式」的描述。

把那六條陣列餵進你自己的頂點緩衝、用你自己的材質畫出來——那部分是你的引擎的工作，不是這個庫的。這不是偷懶，是[架構決策](adr/0008-dimension-agnostic-3d-first.md)：庫的輸出不含任何渲染後端的假設，所以換引擎、換維度、換語言都不需要改核心。

**確定性保證**：同一組 `(JSON, 位置, 面向, seed, dt 序列)` 永遠產生逐位元相同的輸出——同一台機器、不同平台、Haskell 路徑或 C ABI 路徑都一樣。這讓法術可回放、可存檔（只要存那五樣東西）、可用純函數測試。

---

## 1. 選一條路

| 你的宿主是…… | 走這條 | 章節 |
|---|---|---|
| Haskell 專案 | cabal sublibrary，直接 import | [§3](#3-路線-ahaskell-宿主) |
| Unity（C#） | C ABI＋P/Invoke | [§5](#5-路線-cunity-c) |
| Godot、Unreal、自製 C/C++ 引擎 | C ABI，直接 `#include` | [§4](#4-路線-bcc-宿主) |
| 其他任何能載入共享庫的語言（Rust、Zig、Python…） | C ABI，用該語言的 FFI | [§6](#6-路線-d自製前端與其他語言) |

除了第一條，全部走同一份合約：`include/particle_magic.h`。那份 header **就是全部的合約**，而且是凍結的——只會增加宣告，不會改動或移除既有的任何一個。`pm_abi_version()` 讓你在啟動時確認手上的 `.dll` 與你編譯時的 header 同一代。

---

## 2. 資料合約速查

不管走哪條路，你拿到的東西都是同一份，只是型別的包裝不同。

### 2.1 六條欄位

| 欄位 | 型別 | 意義 |
|---|---|---|
| `pos_x` / `pos_y` / `pos_z` | `float` | 粒子在**抽象 3D 世界座標**的位置 |
| `size` | `float` | 粒子的半邊長（世界單位）。billboard 的邊長 = `2 × size` |
| `life` | `float` | 正規化生命週期 0..1（0 = 剛生成，1 = 即將消失）。做淡出、做 LOD、做 shader 變化都靠它 |
| `color` | `uint32` | **`0xRRGGBBAA`**——R 在最高位元組、A 在最低位元組 |

**顏色解包**（這件事目前只寫在這裡，header 沒說）：

```c
uint8_t r = (c >> 24) & 0xFF;
uint8_t g = (c >> 16) & 0xFF;
uint8_t b = (c >>  8) & 0xFF;
uint8_t a =  c        & 0xFF;
```

顏色是**依 `life` 沿著顏色曲線內插後的結果**，屬性（火／雷／⋯）決定曲線兩端，所以你拿到的已經是最終顏色，不需要自己查表。Alpha 通常在生命末端歸零——直接乘進頂點色即可。

### 2.2 批次描述 `batch_info`

粒子在六條陣列裡是**連續分段**存放的，每段是一個批次（batch）。`pm_observe` 回傳批次數 `n`，並填好 `n × 4` 個 int：

| 索引 | 意義 |
|---|---|
| `batch_info[4*i + 0]` | 第 i 批的第一顆粒子在六條陣列裡的位移（offset） |
| `batch_info[4*i + 1]` | 第 i 批的粒子數 |
| `batch_info[4*i + 2]` | 混合模式：`PM_BLEND_ALPHA`(0) / `PM_BLEND_ADDITIVE`(1) |
| `batch_info[4*i + 3]` | billboard 形狀：`PM_SHAPE_SQUARE`(0) |

一批＝一次 draw call（設好混合狀態，畫這一段）。目前每個法術的批次數很少（個位數），`max_batches = 8` 足夠；不夠時 `pm_observe` 回 `PM_ERR_CAPACITY` 而**不寫入任何東西**——你不會拿到畫到一半的幀。

### 2.3 座標系與單位

- **座標系：OpenGL 式右手系——X 右、Y 上、+Z 朝觀者。** 這件事被 `vortex` 力場的外積固定住（旋轉方向是真的有手性的），所以**手性錯了不會崩潰，只會讓漩渦轉反**。
  - Unity / Unreal 是**左手系**（+Z 進畫面）→ 見 [§5.5](#55-座標系轉換)。
  - raylib / OpenGL / Godot 3D 是右手系 → 直接用。
- **時間**：秒。`dt`、`pm_age()` 都是秒。
- **長度**：任意世界單位，由魔法陣 JSON 裡的數字決定（`size: 3.0` 的方陣就是 3 個單位寬）。你自己決定 1 單位是 1 公尺還是 1 像素。

### 2.4 固定時步

模擬假設**固定 `dt`**（[architecture §11](architecture.md#11-不容易擴充與改動的地方明知的代價) 把它列為系統公理）。力場層的確定性與可回放性依賴這一點。

正確做法是 accumulator：渲染幀率浮動，模擬永遠走固定步。

```c
accumulator += frame_time;
while (accumulator >= FIXED_DT) {          /* 每步都 advance */
    pm_advance(spell, FIXED_DT);
    accumulator -= FIXED_DT;
}
pm_observe(spell, ...);                     /* 每個畫面幀只取樣一次 */
```

`pm_advance` 只推進時鐘（有力場時順便積分），取樣發生在 `pm_observe`——所以「一幀跑三個固定步」不會付三倍的取樣成本。

---

## 3. 路線 A：Haskell 宿主

`magic-core` 與 `magic-boundary` 都是 `visibility: public` 的具名 sublibrary，外部 cabal 專案可直接依賴。

```cabal
-- cabal.project
source-repository-package
  type: git
  location: https://github.com/utomore/particle-magic-system.git
  tag: <commit-or-tag>
```

```cabal
-- your-game.cabal
build-depends: particle-magic:magic-boundary
```

你只 import 三個模組，其他一律不是合約的一部分：

```haskell
import Magic.Codec      (loadCircle, renderLoadError)
import Magic.Interface  -- castSpell / advanceSpell / observeSpell / isFinished / spellAge
import Magic.Projection (ViewPlane (..), orthographic, depthOrder)   -- 只有 2D 宿主需要
```

```haskell
runSpell :: BS.ByteString -> IO ()
runSpell bytes =
  case loadCircle bytes of
    Left err -> putStrLn (renderLoadError err)
    Right circle ->
      case castSpell (CastRequest circle ctx) of
        Left cerr   -> print cerr
        Right spell -> loop spell
  where
    ctx = CastContext { casterPos = V3 0 0 0, casterFacing = V3 0 0 1, seed = Seed 42 }

    loop spell = do
      -- 固定時步：一幀可能推進好幾步，但只取樣一次
      let spell' = iterate (advanceSpell (FrameInput dt)) spell !! steps
          FrameOutput bs = observeSpell spell'
      mapM_ drawWithYourRenderer bs      -- rbParticles / rbBlend / rbShape
      if isFinished spell' then pure () else loop spell'
```

`stepSpell` 是 `advanceSpell` 後接 `observeSpell` 的合成，一幀一步時用它比較短。

**2D 宿主**：`orthographic plane p` 回 `(V2, depth)`，`depthOrder plane buffer` 回一個**穩定的由遠而近索引置換**（等深時保持 buffer 原序）。螢幕原點與縮放仍然是你的事——庫只負責丟軸與排序這兩件純數學。

---

## 4. 路線 B：C／C++ 宿主

### 4.1 建置

```
cabal build particle-magic-ffi
```

產物（Windows，`standalone` 內嵌 GHC RTS，約 46 MB）：

```
dist-newstyle/build/x86_64-windows/ghc-9.14.1/particle-magic-0.1.0.0/f/
  particle-magic-ffi/build/particle-magic-ffi/
    particle-magic-ffi.dll        <- 執行期需要
    particle-magic-ffi.dll.a      <- 連結期需要（匯入庫）
```

Linux／macOS 為 `libparticle-magic-ffi.so` / `.dylib`。

```
gcc -Iinclude your_host.c path/to/particle-magic-ffi.dll.a -o game.exe
```

（機器上沒有獨立 gcc 也行：ghcup 隨附的 `clang` 等價，spec 0009 的驗收就是用它做的。）

### 4.2 最小完整迴圈

```c
#include "particle_magic.h"

static float px[PM_MAX_PARTICLES], py[PM_MAX_PARTICLES], pz[PM_MAX_PARTICLES];
static float sz[PM_MAX_PARTICLES], lf[PM_MAX_PARTICLES];
static uint32_t col[PM_MAX_PARTICLES];
static int      info[8 * PM_BATCH_INFO_STRIDE];

int main(void)
{
    char  err[256];
    const float pos[3]    = {0, 0, 0};
    const float facing[3] = {0, 0, 1};

    pm_init();                                   /* 冪等，啟動 GHC RTS */

    if (pm_abi_version() != PM_ABI_VERSION) {    /* header 與 .dll 是同一代嗎 */
        return 1;
    }

    PmSpell *s = pm_cast(json_text, pos, facing, 42, err, sizeof err);
    if (!s) {                                    /* NULL = 失敗，原因在 err */
        fprintf(stderr, "%s\n", err);
        return 1;
    }

    while (!pm_is_finished(s)) {
        pm_advance(s, 1.0f / 60.0f);

        int n = pm_observe(s, px, py, pz, sz, lf, col,
                           PM_MAX_PARTICLES, info, 8);
        if (n < 0) { break; }                    /* PM_ERR_CAPACITY */

        for (int i = 0; i < n; i++) {
            int offset = info[i * PM_BATCH_INFO_STRIDE + 0];
            int count  = info[i * PM_BATCH_INFO_STRIDE + 1];
            int blend  = info[i * PM_BATCH_INFO_STRIDE + 2];
            /* 設好混合狀態，把 [offset, offset+count) 這一段餵進頂點緩衝 */
            draw_your_quads(px + offset, py + offset, pz + offset,
                            sz + offset, lf + offset, col + offset,
                            count, blend);
        }
    }

    pm_free(s);
    pm_shutdown();
    return 0;
}
```

`examples/c/main.c` 是這段的完整可執行版（150 行，印出逐幀摘要而非畫圖）。

### 4.3 錯誤處理

| 情況 | 回傳 |
|---|---|
| `pm_cast` 失敗 | `NULL`，人類可讀的 UTF-8 原因寫進 `err_buf`（保證 NUL 結尾、超長安全截斷；`err_buf` 可為 `NULL`） |
| 想知道**為什麼**失敗 | 改用 `pm_cast_ex(..., &spell)`：回 `PM_OK` / `PM_ERR_JSON`（JSON 不合法或符文 tag 不認識）/ `PM_ERR_BUDGET`（合法，但要求的粒子數超過上限） |
| `pm_observe` 空間不足 | `PM_ERR_CAPACITY`，**一個位元組都不寫**——不會有半更新的幀 |

錯誤訊息與 demo HUD 上顯示的是同一句（共用 `Magic.Codec.renderLoadError`），含 JSON 路徑，例如
`spell JSON error: Error in $.circle.bridge: unknown rune tag "bogus"`。

### 4.4 生命週期規則

- `pm_init()` 冪等，可以被多個子系統各叫一次。
- **一個 handle 屬於一個執行緒**（ADR-0011 D4）。庫內部**沒有鎖**。不同 handle 在不同執行緒是安全的；同一個 handle 跨執行緒不是。
- `pm_free(NULL)` 是 no-op。重複 free、free 過再用是 UB——和任何 C API 一樣。
- **`pm_shutdown()` 之後不能再 `pm_init()`**：GHC 的 RTS 一旦真正 `hs_exit()`，同一個 process 內無法重啟。長駐型宿主（尤其 Unity Editor）**乾脆永遠不要呼叫它**。
- 一個 process 只能有一份 GHC RTS——不要把兩個 GHC 產生的共享庫連進同一個宿主。

---

## 5. 路線 C：Unity（C#）

Unity 走的就是 §4 的 C ABI，只是隔著 P/Invoke。以下是可以直接貼進專案的骨架。

### 5.1 放置 DLL

```
Assets/Plugins/x86_64/particle-magic-ffi.dll
```

在 Inspector 裡把它設為 **Standalone / x86_64**。Editor 也要勾（不然編輯器裡跑不動）。

### 5.2 P/Invoke 宣告

```csharp
using System;
using System.Runtime.InteropServices;

public static class PmNative
{
    const string Dll = "particle-magic-ffi";

    // 與 particle_magic.h 的常數對齊；FFIContractSpec 守護 header 與 Haskell 端，
    // 這一側請自行對照（或用 pm_max_particles() 查詢，見 roadmap §4.2）
    public const int MaxParticles    = 4096;   // PM_MAX_PARTICLES
    public const int BatchInfoStride = 4;      // PM_BATCH_INFO_STRIDE
    public const int AbiVersion      = 1;      // PM_ABI_VERSION
    public const int Ok = 0, ErrJson = -1, ErrBudget = -2, ErrCapacity = -3;
    public const int BlendAlpha = 0, BlendAdditive = 1;

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void pm_init();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void pm_shutdown();

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int pm_abi_version();

    // circle_json 傳 UTF-8 位元組並自行補 '\0'——最不受 Unity scripting backend 影響的作法
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr pm_cast(byte[] circleJsonUtf8,
                                        float[] casterPos, float[] casterFacing,
                                        ulong seed, byte[] errBuf, int errLen);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void pm_advance(IntPtr spell, float dt);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int pm_is_finished(IntPtr spell);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern double pm_age(IntPtr spell);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern int pm_observe(IntPtr spell,
                                        float[] posX, float[] posY, float[] posZ,
                                        float[] size, float[] life, uint[] color,
                                        int capacity, int[] batchInfo, int maxBatches);

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
    public static extern void pm_free(IntPtr spell);
}
```

`float[]` / `uint[]` / `int[]` 都是 blittable，marshaller 會**釘住（pin）原陣列直接傳指標**，不會逐元素複製——所以每幀 `pm_observe` 只有一次跨界呼叫，成本可以忽略。重點是**陣列要重複使用**（欄位而非區域變數），否則每幀都在製造 GC 垃圾。

### 5.3 RTS 生命週期（最容易踩的一個坑）

```csharp
[RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
static void BootParticleMagic()
{
    PmNative.pm_init();
    if (PmNative.pm_abi_version() != PmNative.AbiVersion)
        Debug.LogError("particle-magic ABI mismatch");
}
```

**絕對不要在 `OnDestroy` / `OnApplicationQuit` 呼叫 `pm_shutdown()`。**

原因見 §4.4：GHC 的 RTS 停掉之後就無法在同一個 process 重啟。而 Unity Editor 在停止播放時**不會卸載 native plugin**——下一次按 Play 還是同一個 process。你會得到「第一次跑正常、第二次直接掛掉」這種最難查的症狀。

正確做法：`pm_init()` 一次，之後就讓它活著。真正的清理只有 `pm_free()`（每個法術一次），這個一定要做。

```csharp
void OnDestroy()
{
    if (spell != IntPtr.Zero) { PmNative.pm_free(spell); spell = IntPtr.Zero; }
    // 不呼叫 pm_shutdown()
}
```

### 5.4 每幀

```csharp
public class SpellRenderer : MonoBehaviour
{
    const int Cap = PmNative.MaxParticles, MaxBatches = 8;
    const float FixedDt = 1f / 60f;

    // 重複使用的緩衝——每幀重新配置就是在餵 GC
    readonly float[] px = new float[Cap], py = new float[Cap], pz = new float[Cap];
    readonly float[] sz = new float[Cap], lf = new float[Cap];
    readonly uint[]  col = new uint[Cap];
    readonly int[]   info = new int[MaxBatches * PmNative.BatchInfoStride];

    IntPtr spell = IntPtr.Zero;
    float  accumulator;

    public void Cast(string circleJson, Vector3 pos, Vector3 facing, ulong seed)
    {
        if (spell != IntPtr.Zero) PmNative.pm_free(spell);

        var json = System.Text.Encoding.UTF8.GetBytes(circleJson + "\0");
        var err  = new byte[256];
        var p    = ToPm(pos);
        var f    = ToPm(facing);

        spell = PmNative.pm_cast(json, p, f, seed, err, err.Length);
        if (spell == IntPtr.Zero)
        {
            int len = Array.IndexOf(err, (byte)0);
            Debug.LogError(System.Text.Encoding.UTF8.GetString(err, 0, len < 0 ? err.Length : len));
        }
    }

    void Update()
    {
        if (spell == IntPtr.Zero) return;

        // 固定時步 accumulator：模擬永遠走 FixedDt，畫面幀率隨意
        accumulator += Time.deltaTime;
        while (accumulator >= FixedDt)
        {
            PmNative.pm_advance(spell, FixedDt);
            accumulator -= FixedDt;
        }

        int n = PmNative.pm_observe(spell, px, py, pz, sz, lf, col,
                                    Cap, info, MaxBatches);
        if (n < 0) { Debug.LogWarning("pm_observe: capacity"); return; }

        for (int i = 0; i < n; i++)
        {
            int offset = info[i * PmNative.BatchInfoStride + 0];
            int count  = info[i * PmNative.BatchInfoStride + 1];
            int blend  = info[i * PmNative.BatchInfoStride + 2];
            BuildMesh(offset, count, blend);       // 你的 Mesh / DrawProcedural
        }

        if (PmNative.pm_is_finished(spell) != 0)
        {
            PmNative.pm_free(spell);
            spell = IntPtr.Zero;
        }
    }

    static Color32 Unpack(uint c) =>
        new Color32((byte)(c >> 24), (byte)(c >> 16), (byte)(c >> 8), (byte)c);

    // 世界座標：右手系（+Z 朝觀者） -> Unity 左手系（+Z 進畫面）
    static float[] ToPm(Vector3 v)   => new[] { v.x, v.y, -v.z };
    static Vector3 FromPm(int i, float[] x, float[] y, float[] z)
                                     => new Vector3(x[i], y[i], -z[i]);
}
```

### 5.5 座標系轉換

庫是**右手系**（X 右、Y 上、**+Z 朝觀者**），Unity 是**左手系**（+Z 進畫面）。轉換就是**翻 Z**——進去的輸入翻一次，出來的位置翻一次（上面的 `ToPm` / `FromPm`）。

翻不翻不會崩潰，只有一個症狀會露餡：**`vortex` 力場的旋轉方向會反過來**（外積是有手性的）。純解析式的法術（沒有 `fields`）看起來會完全一樣，所以這個 bug 很容易在加上力場之後才被發現——寧可一開始就翻對。

### 5.6 混合模式對照

| `batch_info[+2]` | 意義 | Unity 材質 |
|---|---|---|
| `PM_BLEND_ALPHA` (0) | 一般 alpha 混合 | `Blend SrcAlpha OneMinusSrcAlpha`，`ZWrite Off` |
| `PM_BLEND_ADDITIVE` (1) | 加法混合（火、雷這類發光體） | `Blend SrcAlpha One`，`ZWrite Off` |

加法混合的批次**不需要深度排序**（加法可交換），alpha 批次需要——目前 3D 路徑的深度排序[記帳在效能 spec](roadmap.md#31-效能被-7-份-spec-指名的最大一筆)，所以在那之前，alpha 批次的排序請由宿主自行處理（或優先使用加法混合的屬性）。

### 5.7 建 Mesh 的兩條路

- **簡單版**：CPU 端把每顆粒子展開成兩個三角形（4 頂點），寫進一個重複使用的 `Mesh`，`mesh.SetVertices` / `SetColors` / `SetIndices`。4096 顆＝16384 頂點，Unity 完全吃得下。
- **快版**：把六條陣列丟進 `ComputeBuffer`，用 `Graphics.DrawProcedural` 在 vertex shader 裡展開 billboard。省掉 CPU 端的展開與上傳量。這也是 demo 在 raylib 端走的路數（[ADR-0009](adr/0009-dynamic-quad-mesh-rendering.md)：整批一次 draw call，draw call 數＝批次數而非粒子數）。

---

## 6. 路線 D：自製前端與其他語言

任何能載入共享庫、能宣告 C 函數的環境都接得上（Rust `extern "C"`、Python `ctypes`、Zig `@cImport`、Godot GDExtension⋯）。合約完全一樣，只有以下幾條**不分語言的規則**：

1. `pm_init()` 一次，之後不要 `pm_shutdown()`（除非你真的要結束 process）。
2. 啟動時比對 `pm_abi_version()` 與你編譯時的 `PM_ABI_VERSION`。
3. 六條陣列由**你**配置、由**你**持有，長度至少 `PM_MAX_PARTICLES`；庫只往裡面寫。
4. 一個 handle 一個執行緒。
5. 固定 `dt`；一幀多步 `advance`、只 `observe` 一次。
6. `pm_observe` 回負數＝什麼都沒寫；不要用上一幀的殘留資料當這一幀畫。
7. 顏色是 `0xRRGGBBAA`；位置是右手系。
8. 每個 `pm_cast` 配一個 `pm_free`。

---

## 7. 哪些事情是**你**要做的

庫刻意不做的清單。看到這裡如果覺得「怎麼這麼多」——這正是它能同時服務 Unity、Godot 和一個 raylib demo 的原因。

| 你的責任 | 為什麼不在庫裡 |
|---|---|
| 頂點緩衝、材質、shader、混合狀態 | 每個引擎都不一樣；輸出格式因此零渲染依賴（[architecture §5.2](architecture.md#52-輸出格式renderbatch-串流)） |
| 相機與投影 | 3D 透視是引擎的事；2D 正交的**純數學**部分庫有提供（Haskell 宿主用 `Magic.Projection`；C ABI 的匯出[記帳在候選 spec B](roadmap.md#42-為什麼建議-a效能作為-0010-主線)） |
| 3D 的深度排序 | 見 §5.6 |
| 多個法術同時存在時的管理與總量配額 | 宿主持有多個 handle 即可；全域配額策略屬遊戲層（[architecture §8.4](architecture.md#8-未來可能遇到的問題)），[記帳在候選 spec C](roadmap.md#45-cde-的位置) |
| 魔法陣 JSON 從哪來（檔案？資料庫？玩家編輯器？） | 庫只認得字串 |
| 熱重載 | 政策是「重載＝重施法」：重新 `pm_cast` 就好，庫不提供遷移中狀態的 API（[ADR-0010 D8](adr/0010-force-field-composition.md)） |
| 音效、傷害判定、命中框 | 這個庫只管粒子；魔法的**遊戲**語意是你的 |

---

## 8. 目前的限制（誠實清單）

寫在合約裡的事實，不是 bug。完整版與各自的記帳位置見 [roadmap.md](roadmap.md)。

| 限制 | 說明 |
|---|---|
| **粒子上限 4096** | `PM_MAX_PARTICLES`；架構目標是 1e4–1e5，效能 spec 尚未動工。超過上限的魔法陣在 `pm_cast` 就會被擋下（`PM_ERR_BUDGET`），不會在執行期爆掉 |
| **一次一張陣** | 沒有多陣合成／疊加 API。想同時放多個法術＝持有多個 handle，總量控制是你的事 |
| **單執行緒 handle** | 庫內無鎖 |
| **RTS 不可重啟** | `pm_shutdown()` 之後不能再 `pm_init()`；一個 process 一份 GHC RTS |
| **DLL 約 46 MB** | `standalone` 內嵌整個 GHC RTS 的代價；換來的是宿主端零 Haskell 依賴 |
| **只有 win64 被完整實測** | `.so` / `.dylib` 由 cabal stanza 天然涵蓋，但沒有列入驗收 |
| **只有方形 billboard** | `PM_SHAPE_SQUARE` 是目前唯一的形狀碼 |
| **C ABI 沒有投影函數** | Haskell 宿主有 `Magic.Projection`；C 宿主目前要自己丟軸＋排序（很簡單：丟一軸、依剩下那軸由遠而近穩定排序） |

---

## 9. 版本與相容性承諾

| 合約 | 承諾 |
|---|---|
| `include/particle_magic.h` | **只加不改**。既有的每個函數簽名、常數值、`batch_info` 佈局都不會變。新增功能＝新增宣告 |
| `pm_abi_version()` | 上述承諾破裂時（如果真有那一天）才會遞增。啟動時比對它 |
| 魔法陣 JSON `"version"` 欄位 | schema v1。未來遞增時，`Magic.Codec` 保留舊版解碼器並提供 migrate，舊魔法檔不會失效 |
| Haskell 側 `Magic.Interface` / `Magic.Codec` / `Magic.Projection` | 各自的 func-spec 驗收紀錄明列「凍結介面清單」；凍結後的變更視同架構變更，要先改 ADR |
| 決定論 | 同一組輸入永遠產生逐位元相同的輸出，且**兩條路徑（Haskell／C ABI）的結果相同**——這不是文件承諾，是 `test/Acceptance9Spec.hs` 的斷言 |
