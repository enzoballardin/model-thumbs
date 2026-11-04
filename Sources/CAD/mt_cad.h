#ifndef MT_CAD_H
#define MT_CAD_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float *positions;      /* x,y,z triples */
    int vertexCount;
    unsigned int *indices; /* 3 per triangle */
    int indexCount;
    char error[256];
} MTCadMesh;

/* kind: 0 = STEP, 1 = IGES, 2 = BREP. Returns 0 on success. */
int mt_cad_load(const char *path, int kind, MTCadMesh *out);
void mt_cad_free(MTCadMesh *mesh);

#ifdef __cplusplus
}
#endif

#endif
