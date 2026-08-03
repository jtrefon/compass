#include "CFAISSWrapper.h"
#include <faiss/c_api/faiss_c.h>
#include <faiss/c_api/Index_c.h>
#include <faiss/c_api/index_factory_c.h>
#include <faiss/c_api/index_io_c.h>
#include <faiss/c_api/error_c.h>
#include <faiss/c_api/impl/AuxIndexStructures_c.h>

int vs_index_create(FAISSIndexRef* out_idx, int d, const char* factory, int metric) {
    FaissIndex* idx = NULL;
    int code = faiss_index_factory(&idx, d, factory, (FaissMetricType)metric);
    *out_idx = (FAISSIndexRef)idx;
    return code;
}

int vs_index_add_with_ids(FAISSIndexRef idx, int64_t n, const float* vectors, const int64_t* ids) {
    return faiss_Index_add_with_ids((FaissIndex*)idx, n, vectors, ids);
}

int vs_index_search(FAISSIndexRef idx, int64_t n, const float* query, int64_t k, float* distances, int64_t* labels) {
    return faiss_Index_search((const FaissIndex*)idx, n, query, k, distances, labels);
}

int vs_index_remove_ids(FAISSIndexRef idx, const int64_t* ids, size_t n) {
    FaissIDSelectorBatch* sel = NULL;
    int code = faiss_IDSelectorBatch_new(&sel, n, ids);
    if (code != 0) return code;
    size_t n_removed = 0;
    code = faiss_Index_remove_ids((FaissIndex*)idx, (FaissIDSelector*)sel, &n_removed);
    faiss_IDSelector_free((FaissIDSelector*)sel);
    return code;
}

int vs_index_reset(FAISSIndexRef idx) {
    return faiss_Index_reset((FaissIndex*)idx);
}

int64_t vs_index_count(FAISSIndexRef idx) {
    return (int64_t)faiss_Index_ntotal((const FaissIndex*)idx);
}

int vs_index_save(FAISSIndexRef idx, const char* path) {
    return faiss_write_index_fname((const FaissIndex*)idx, path);
}

int vs_index_load(const char* path, FAISSIndexRef* out_idx) {
    FaissIndex* idx = NULL;
    int code = faiss_read_index_fname(path, 0, &idx);
    *out_idx = (FAISSIndexRef)idx;
    return code;
}

void vs_index_free(FAISSIndexRef idx) {
    faiss_Index_free((FaissIndex*)idx);
}

const char* vs_last_error(void) {
    return faiss_get_last_error();
}
