# KV Cache Quantization in compass

## Terminology

There are two distinct technologies that are often confused:

### 4-bit KV Cache Quantization (what we use)

Our `kvCache4BitEnabled` setting enables MLX's built-in 4-bit quantization of the
KV cache. When active, `GenerateParameters(kvBits: 4)` tells MLX to store KV
cache entries at 4-bit precision instead of the default FP16.

- **Mechanism**: Direct uniform quantization of K and V tensors to 4-bit integers
- **Compression**: ~4x reduction in KV cache memory (FP16 → 4-bit)
- **Quality**: Slight quality degradation; acceptable for most use cases
- **Performance**: Can improve generation speed (less memory bandwidth) at the
  cost of some prefill speed (dequantization overhead)
- **No calibration needed**: Works out of the box with any model

### TurboQuant (Google, ICLR 2026 — NOT what we use)

[TurboQuant](https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/)
is Google's PolarQuant-based KV cache compression algorithm. It is a
fundamentally different and more sophisticated approach:

- **Mechanism**: Walsh-Hadamard rotation → Lloyd-Max optimal scalar quantization
  → bit-packing into uint32
- **Compression**: 3.8x (4-bit) to 6.4x (2-bit) reduction vs FP16
- **Quality**: Near-lossless (cosine similarity >0.99 at 4-bit for Qwen3-4B)
- **Data-oblivious**: No calibration data needed; rotation matrix is fixed
- **Status**: Experimental MLX implementations exist
  ([rachittshah/mlx-turboquant](https://github.com/rachittshah/mlx-turboquant),
  [ediestel/turboquant-plus-mlx](https://github.com/ediestel/turboquant-plus-mlx))
  but not yet upstreamed into mlx-lm

### Key Differences

| Feature             | 4-bit KV Cache (ours)    | TurboQuant               |
|---------------------|--------------------------|--------------------------|
| Algorithm           | Uniform quantization     | PolarQuant + WHT rotation |
| Compression vs FP16 | ~4x                      | 3.8x–6.4x                |
| Quality             | Good                     | Near-lossless            |
| Dequant cost        | Low (lookup)             | Higher (WHT + lookup)    |
| Implementation      | MLX built-in (`kvBits`)  | Custom Metal kernels     |
| Availability        | Production-ready         | Experimental             |

## Configuration

### Settings UI

The "4-bit KV Cache" toggle in Local Model Settings controls this feature.

### Environment Variable

```
COMPASS_LOCAL_MODEL_KV_CACHE_4BIT=1   # Enable
COMPASS_LOCAL_MODEL_KV_CACHE_4BIT=0   # Disable (default)
```

### UserDefaults Key

```
LocalModel.KVCache4BitEnabled (Bool, default: false)
```

### Code Reference

- `LocalModelInferenceConfiguration.kvCache4BitEnabled` — the resolved flag
- `LocalModelInferenceOverrides.kvCache4BitEnabled` — per-test override
- `LocalModelSelectionStore.isKVCache4BitEnabled()` — persisted user preference
- `GenerateParameters(kvBits: 4)` — where MLX is told to use 4-bit KV cache

## Current Model: Qwen3.5-4B-MLX-4bit

- **Max context**: 262,144 tokens (256K) per `text_config.max_position_embeddings`
- **Model weights**: ~3.03 GB (4-bit quantized)
- **KV cache at 262K with 4-bit**: Significantly reduced vs FP16
- **Supported**: `supportsQuantizedKVCache = true` (default)
