// Super Gloss core C API. All strings are UTF-8. Returned strings must be freed
// with sg_free_string, returned buffers with sg_free_bytes.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SGLibrary SGLibrary;

SGLibrary *sg_library_new(const char *cache_dir);
void sg_library_free(SGLibrary *lib);

void sg_configure(const SGLibrary *lib, const char *config_json);
void sg_set_enabled(const SGLibrary *lib, const char *dict_id, bool enabled);
void sg_reindex(const SGLibrary *lib, const char *dict_id);
uint64_t sg_generation(const SGLibrary *lib);

char *sg_dictionaries(const SGLibrary *lib);
char *sg_suggest(const SGLibrary *lib, const char *query, uint32_t limit);
char *sg_lookup(const SGLibrary *lib, const char *word);
char *sg_random_word(const SGLibrary *lib);

uint8_t *sg_serve(const SGLibrary *lib, const char *url, size_t *out_len, char **out_mime);
uint8_t *sg_audio(const SGLibrary *lib, const char *dict_id, const char *path, size_t *out_len);

void sg_free_string(char *s);
void sg_free_bytes(uint8_t *ptr, size_t len);
