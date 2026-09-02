#ifndef ZIG_WIND_COM_HELPERS_H
#define ZIG_WIND_COM_HELPERS_H

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <oaidl.h>
#include <oleauto.h>
#include <ocidl.h>

typedef struct wind_event_sink wind_event_sink;

typedef struct wind_subscription_event {
    LONG state;
    ULONGLONG request_id;
    LONG error_code;
} wind_subscription_event;

HRESULT wind_com_initialize(void);
void wind_com_uninitialize(void);
void wind_variant_init(VARIANT *variant);
void wind_variant_clear(VARIANT *variant);
void wind_get_clsid(CLSID *out);
HRESULT wind_create_dispatch(void **out);
ULONG wind_release_dispatch(void *dispatch);
HRESULT wind_dispatch_invoke(void *dispatch, DISPID member, VARIANT *args, UINT arg_count, VARIANT *result);
HRESULT wind_dispatch_get_id(void *dispatch, const OLECHAR *name, DISPID *out);

void wind_variant_set_bstr(VARIANT *variant, const OLECHAR *value);
void wind_variant_set_i4(VARIANT *variant, LONG value);
void wind_variant_set_i8(VARIANT *variant, LONGLONG value);
void wind_variant_set_ui8(VARIANT *variant, ULONGLONG value);
void wind_variant_set_variant_ref(VARIANT *variant, VARIANT *value);
void wind_variant_set_i4_ref(VARIANT *variant, LONG *value);
LONG wind_variant_array_count(const VARIANT *variant);
HRESULT wind_variant_array_element(const VARIANT *array_variant, LONG index, VARIANT *out);
VARTYPE wind_variant_type(const VARIANT *variant);
BSTR wind_variant_bstr(const VARIANT *variant);
LONG wind_variant_i4(const VARIANT *variant);
LONGLONG wind_variant_i8(const VARIANT *variant);
DOUBLE wind_variant_r8(const VARIANT *variant);
FLOAT wind_variant_r4(const VARIANT *variant);
VARIANT_BOOL wind_variant_bool(const VARIANT *variant);
DATE wind_variant_date(const VARIANT *variant);
UINT wind_bstr_len(BSTR value);

HRESULT wind_event_sink_create(void *dispatch, wind_event_sink **out);
void wind_event_sink_destroy(wind_event_sink *sink);
void wind_pump_messages(void);
BOOL wind_event_sink_pop(wind_event_sink *sink, wind_subscription_event *out);
BOOL wind_event_sink_take_overflow(wind_event_sink *sink);

#endif
