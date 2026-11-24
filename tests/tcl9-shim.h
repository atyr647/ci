/* tcl9-shim.h - what Tcl 9's C API changes that bites code written for 8.6, checked without a Tcl 9 install.
 * Tcl 9 gives lengths and counts the type Tcl_Size (ptrdiff_t, 64 bits) where 8.6 has int; a call that hands such a
 * function the address of an int then writes 8 bytes into 4 (or reads garbage). This header is included before the
 * source (gcc -include) with Tcl 8.6's own tcl.h: it makes Tcl_Size wide, and redeclares the functions that take or
 * return a size through a pointer with Tcl 9's prototypes, so that `gcc -fsyntax-only -Werror=incompatible-pointer-types`
 * reports every `int *` given to one. Nothing is linked. tests/steps.d/12-tcl9-capi.sh runs it. */
#include <stddef.h>
#include <tcl.h>
#define TCL_SIZE_MAX PTRDIFF_MAX   /* the sources' own `#ifndef TCL_SIZE_MAX typedef int Tcl_Size;` is then skipped */
typedef ptrdiff_t Tcl_Size;
extern char *Tcl9_GetStringFromObj(Tcl_Obj *, Tcl_Size *);
extern unsigned char *Tcl9_GetByteArrayFromObj(Tcl_Obj *, Tcl_Size *);
extern unsigned char *Tcl9_SetByteArrayLength(Tcl_Obj *, Tcl_Size);
extern int Tcl9_ListObjGetElements(Tcl_Interp *, Tcl_Obj *, Tcl_Size *, Tcl_Obj ***);
extern int Tcl9_ListObjLength(Tcl_Interp *, Tcl_Obj *, Tcl_Size *);
extern int Tcl9_ListObjIndex(Tcl_Interp *, Tcl_Obj *, Tcl_Size, Tcl_Obj **);
extern int Tcl9_DictObjSize(Tcl_Interp *, Tcl_Obj *, Tcl_Size *);
extern unsigned short *Tcl9_GetUnicodeFromObj(Tcl_Obj *, Tcl_Size *);
extern Tcl_Size Tcl9_GetCharLength(Tcl_Obj *);
extern Tcl_Size Tcl9_Read(Tcl_Channel, char *, Tcl_Size);
#undef Tcl_GetStringFromObj
#undef Tcl_GetByteArrayFromObj
#undef Tcl_SetByteArrayLength
#undef Tcl_ListObjGetElements
#undef Tcl_ListObjLength
#undef Tcl_ListObjIndex
#undef Tcl_DictObjSize
#undef Tcl_GetUnicodeFromObj
#undef Tcl_GetCharLength
#undef Tcl_Read
#define Tcl_GetStringFromObj Tcl9_GetStringFromObj
#define Tcl_GetByteArrayFromObj Tcl9_GetByteArrayFromObj
#define Tcl_SetByteArrayLength Tcl9_SetByteArrayLength
#define Tcl_ListObjGetElements Tcl9_ListObjGetElements
#define Tcl_ListObjLength Tcl9_ListObjLength
#define Tcl_ListObjIndex Tcl9_ListObjIndex
#define Tcl_DictObjSize Tcl9_DictObjSize
#define Tcl_GetUnicodeFromObj Tcl9_GetUnicodeFromObj
#define Tcl_GetCharLength Tcl9_GetCharLength
#define Tcl_Read Tcl9_Read
