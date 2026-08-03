#include <stdint.h>
#include <stddef.h>

typedef void* FAISSIndexRef;

int vs_index_create(FAISSIndexRef* out_idx, int d, const char* factory, int metric);
int vs_index_add_with_ids(FAISSIndexRef idx, int64_t n, const float* vectors, const int64_t* ids);
int vs_index_search(FAISSIndexRef idx, int64_t n, const float* query, int64_t k, float* distances, int64_t* labels);
int vs_index_remove_ids(FAISSIndexRef idx, const int64_t* ids, size_t n);
int vs_index_reset(FAISSIndexRef idx);
int64_t vs_index_count(FAISSIndexRef idx);
int vs_index_save(FAISSIndexRef idx, const char* path);
int vs_index_load(const char* path, FAISSIndexRef* out_idx);
void vs_index_free(FAISSIndexRef idx);
const char* vs_last_error(void);
