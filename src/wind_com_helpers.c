#include "wind_com_helpers.h"

static const CLSID wind_clsid =
    {0x3f16f4ab, 0xce92, 0x4848, {0x96, 0x44, 0x39, 0xe6, 0x7c, 0x6e, 0x1c, 0xce}};
static const IID wind_events_iid =
    {0x831f1c39, 0xc657, 0x4849, {0xbe, 0x13, 0xc5, 0x2a, 0x9b, 0xc0, 0x64, 0xed}};

enum { WIND_EVENT_QUEUE_CAPACITY = 256 };

struct wind_event_sink {
    IDispatch dispatch;
    LONG ref_count;
    IConnectionPoint *connection_point;
    DWORD cookie;
    CRITICAL_SECTION lock;
    wind_subscription_event events[WIND_EVENT_QUEUE_CAPACITY];
    UINT head;
    UINT count;
    BOOL overflowed;
};

static HRESULT STDMETHODCALLTYPE wind_sink_query_interface(IDispatch *self, REFIID iid, void **out);
static ULONG STDMETHODCALLTYPE wind_sink_add_ref(IDispatch *self);
static ULONG STDMETHODCALLTYPE wind_sink_release(IDispatch *self);
static HRESULT STDMETHODCALLTYPE wind_sink_get_type_info_count(IDispatch *self, UINT *out);
static HRESULT STDMETHODCALLTYPE wind_sink_get_type_info(IDispatch *self, UINT index, LCID lcid, ITypeInfo **out);
static HRESULT STDMETHODCALLTYPE wind_sink_get_ids_of_names(IDispatch *self, REFIID iid, LPOLESTR *names, UINT count, LCID lcid, DISPID *out);
static HRESULT STDMETHODCALLTYPE wind_sink_invoke(IDispatch *self, DISPID member, REFIID iid, LCID lcid, WORD flags, DISPPARAMS *params, VARIANT *result, EXCEPINFO *exception, UINT *argument_error);

static IDispatchVtbl wind_sink_vtbl = {
    wind_sink_query_interface,
    wind_sink_add_ref,
    wind_sink_release,
    wind_sink_get_type_info_count,
    wind_sink_get_type_info,
    wind_sink_get_ids_of_names,
    wind_sink_invoke,
};

static struct wind_event_sink *wind_sink_from_dispatch(IDispatch *dispatch) {
    return (struct wind_event_sink *)dispatch;
}

HRESULT wind_com_initialize(void) {
    return CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
}

void wind_com_uninitialize(void) {
    CoUninitialize();
}

void wind_variant_init(VARIANT *variant) {
    VariantInit(variant);
}

void wind_variant_clear(VARIANT *variant) {
    VariantClear(variant);
}

void wind_get_clsid(CLSID *out) {
    *out = wind_clsid;
}

HRESULT wind_create_dispatch(void **out) {
    return CoCreateInstance(&wind_clsid, NULL, CLSCTX_ALL, &IID_IDispatch, out);
}

ULONG wind_release_dispatch(void *dispatch) {
    return ((IDispatch *)dispatch)->lpVtbl->Release((IDispatch *)dispatch);
}

HRESULT wind_dispatch_invoke(
    void *dispatch,
    DISPID member,
    VARIANT *args,
    UINT arg_count,
    VARIANT *result
) {
    DISPPARAMS params;
    EXCEPINFO exception;
    UINT argument_error = 0;

    params.rgvarg = args;
    params.rgdispidNamedArgs = NULL;
    params.cArgs = arg_count;
    params.cNamedArgs = 0;
    ZeroMemory(&exception, sizeof(exception));

    return ((IDispatch *)dispatch)->lpVtbl->Invoke(
        (IDispatch *)dispatch,
        member,
        &IID_NULL,
        LOCALE_USER_DEFAULT,
        DISPATCH_METHOD,
        &params,
        result,
        &exception,
        &argument_error
    );
}

HRESULT wind_dispatch_get_id(void *dispatch, const OLECHAR *name, DISPID *out) {
    LPOLESTR names[] = { (LPOLESTR)name };
    return ((IDispatch *)dispatch)->lpVtbl->GetIDsOfNames(
        (IDispatch *)dispatch,
        &IID_NULL,
        names,
        1,
        LOCALE_USER_DEFAULT,
        out
    );
}

void wind_variant_set_bstr(VARIANT *variant, const OLECHAR *value) {
    VariantInit(variant);
    V_VT(variant) = VT_BSTR;
    V_BSTR(variant) = SysAllocString(value);
}

void wind_variant_set_i4(VARIANT *variant, LONG value) {
    VariantInit(variant);
    V_VT(variant) = VT_I4;
    V_I4(variant) = value;
}

void wind_variant_set_i8(VARIANT *variant, LONGLONG value) {
    VariantInit(variant);
    V_VT(variant) = VT_I8;
    V_I8(variant) = value;
}

void wind_variant_set_ui8(VARIANT *variant, ULONGLONG value) {
    VariantInit(variant);
    V_VT(variant) = VT_UI8;
    V_UI8(variant) = value;
}

void wind_variant_set_variant_ref(VARIANT *variant, VARIANT *value) {
    VariantInit(variant);
    V_VT(variant) = VT_BYREF | VT_VARIANT;
    V_VARIANTREF(variant) = value;
}

void wind_variant_set_i4_ref(VARIANT *variant, LONG *value) {
    VariantInit(variant);
    V_VT(variant) = VT_BYREF | VT_I4;
    V_I4REF(variant) = value;
}

static LONG wind_safearray_len(SAFEARRAY *array) {
    if (array == NULL) return 0;
    UINT dimensions = SafeArrayGetDim(array);
    LONG total = 1;
    for (UINT dimension = 1; dimension <= dimensions; ++dimension) {
        LONG lower = 0;
        LONG upper = -1;
        if (FAILED(SafeArrayGetLBound(array, dimension, &lower)) ||
            FAILED(SafeArrayGetUBound(array, dimension, &upper))) return 0;
        total *= upper - lower + 1;
    }
    return total;
}

LONG wind_variant_array_count(const VARIANT *variant) {
    if (!(V_VT(variant) & VT_ARRAY)) return 0;
    return wind_safearray_len(V_ARRAY(variant));
}

/// Raw pointer to the array's data block.
///
/// Wind's results are multi-dimensional (time x code x field), and
/// SafeArrayGetElement wants one index per dimension — handing it a single LONG
/// reads past the caller's index array and returns the wrong element. Wind's own
/// WAPIWrapperCpp does not use it either: WindDataParser::GetVarFromArray walks
/// pvData with a flat index, exactly like the Linux backend does. Same layout,
/// one code path, no per-element COM call.
PVOID wind_variant_array_data(const VARIANT *variant) {
    SAFEARRAY *array;

    if (!(V_VT(variant) & VT_ARRAY)) return NULL;
    array = V_ARRAY(variant);
    if (array == NULL) return NULL;
    return array->pvData;
}

VARTYPE wind_variant_type(const VARIANT *variant) { return V_VT(variant); }
BSTR wind_variant_bstr(const VARIANT *variant) { return V_BSTR(variant); }
LONG wind_variant_i4(const VARIANT *variant) { return V_I4(variant); }
LONGLONG wind_variant_i8(const VARIANT *variant) { return V_I8(variant); }
DOUBLE wind_variant_r8(const VARIANT *variant) { return V_R8(variant); }
FLOAT wind_variant_r4(const VARIANT *variant) { return V_R4(variant); }
VARIANT_BOOL wind_variant_bool(const VARIANT *variant) { return V_BOOL(variant); }
DATE wind_variant_date(const VARIANT *variant) { return V_DATE(variant); }
UINT wind_bstr_len(BSTR value) { return SysStringLen(value); }

static HRESULT STDMETHODCALLTYPE wind_sink_query_interface(IDispatch *self, REFIID iid, void **out) {
    if (out == NULL) return E_POINTER;
    *out = NULL;
    if (IsEqualIID(iid, &IID_IUnknown) || IsEqualIID(iid, &IID_IDispatch) || IsEqualIID(iid, &wind_events_iid)) {
        *out = self;
        wind_sink_add_ref(self);
        return S_OK;
    }
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE wind_sink_add_ref(IDispatch *self) {
    struct wind_event_sink *sink = wind_sink_from_dispatch(self);
    return (ULONG)InterlockedIncrement(&sink->ref_count);
}

static ULONG STDMETHODCALLTYPE wind_sink_release(IDispatch *self) {
    struct wind_event_sink *sink = wind_sink_from_dispatch(self);
    LONG count = InterlockedDecrement(&sink->ref_count);
    if (count == 0) {
        DeleteCriticalSection(&sink->lock);
        HeapFree(GetProcessHeap(), 0, sink);
    }
    return (ULONG)count;
}

static HRESULT STDMETHODCALLTYPE wind_sink_get_type_info_count(IDispatch *self, UINT *out) {
    (void)self;
    if (out != NULL) *out = 0;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE wind_sink_get_type_info(IDispatch *self, UINT index, LCID lcid, ITypeInfo **out) {
    (void)self; (void)index; (void)lcid;
    if (out != NULL) *out = NULL;
    return E_NOTIMPL;
}

static HRESULT STDMETHODCALLTYPE wind_sink_get_ids_of_names(IDispatch *self, REFIID iid, LPOLESTR *names, UINT count, LCID lcid, DISPID *out) {
    (void)self; (void)iid; (void)names; (void)count; (void)lcid; (void)out;
    return DISP_E_UNKNOWNNAME;
}

static HRESULT STDMETHODCALLTYPE wind_sink_invoke(IDispatch *self, DISPID member, REFIID iid, LCID lcid, WORD flags, DISPPARAMS *params, VARIANT *result, EXCEPINFO *exception, UINT *argument_error) {
    (void)iid; (void)lcid; (void)flags; (void)result; (void)exception; (void)argument_error;
    if (member != 2 || params == NULL || params->cArgs < 3) return S_OK;

    VARIANT *args = params->rgvarg;
    if ((V_VT(&args[0]) & VT_TYPEMASK) != VT_I4 ||
        (V_VT(&args[1]) & VT_TYPEMASK) != VT_I8 ||
        (V_VT(&args[2]) & VT_TYPEMASK) != VT_I4) return DISP_E_TYPEMISMATCH;

    struct wind_event_sink *sink = wind_sink_from_dispatch(self);
    EnterCriticalSection(&sink->lock);
    if (sink->count == WIND_EVENT_QUEUE_CAPACITY) {
        sink->head = (sink->head + 1) % WIND_EVENT_QUEUE_CAPACITY;
        sink->count -= 1;
        sink->overflowed = TRUE;
    }
    UINT tail = (sink->head + sink->count) % WIND_EVENT_QUEUE_CAPACITY;
    sink->events[tail].state = V_I4(&args[2]);
    sink->events[tail].request_id = (ULONGLONG)V_I8(&args[1]);
    sink->events[tail].error_code = V_I4(&args[0]);
    sink->count += 1;
    LeaveCriticalSection(&sink->lock);
    return S_OK;
}

HRESULT wind_event_sink_create(void *dispatch, wind_event_sink **out) {
    IConnectionPointContainer *container = NULL;
    IConnectionPoint *point = NULL;
    struct wind_event_sink *sink = NULL;
    HRESULT result;

    if (out == NULL) return E_POINTER;
    *out = NULL;
    result = ((IDispatch *)dispatch)->lpVtbl->QueryInterface((IDispatch *)dispatch, &IID_IConnectionPointContainer, (void **)&container);
    if (FAILED(result)) return result;
    result = container->lpVtbl->FindConnectionPoint(container, &wind_events_iid, &point);
    container->lpVtbl->Release(container);
    if (FAILED(result)) return result;

    sink = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*sink));
    if (sink == NULL) {
        point->lpVtbl->Release(point);
        return E_OUTOFMEMORY;
    }
    sink->dispatch.lpVtbl = &wind_sink_vtbl;
    sink->ref_count = 1;
    sink->connection_point = point;
    InitializeCriticalSection(&sink->lock);

    result = point->lpVtbl->Advise(point, (IUnknown *)&sink->dispatch, &sink->cookie);
    if (FAILED(result)) {
        point->lpVtbl->Release(point);
        DeleteCriticalSection(&sink->lock);
        HeapFree(GetProcessHeap(), 0, sink);
        return result;
    }

    *out = sink;
    return S_OK;
}

void wind_event_sink_destroy(wind_event_sink *sink) {
    if (sink == NULL) return;
    if (sink->connection_point != NULL) {
        sink->connection_point->lpVtbl->Unadvise(sink->connection_point, sink->cookie);
        sink->connection_point->lpVtbl->Release(sink->connection_point);
        sink->connection_point = NULL;
    }
    wind_sink_release(&sink->dispatch);
}

void wind_pump_messages(void) {
    MSG message;
    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
}

BOOL wind_event_sink_pop(wind_event_sink *sink, wind_subscription_event *out) {
    BOOL has_event = FALSE;
    if (sink == NULL || out == NULL) return FALSE;
    EnterCriticalSection(&sink->lock);
    if (sink->count != 0) {
        *out = sink->events[sink->head];
        sink->head = (sink->head + 1) % WIND_EVENT_QUEUE_CAPACITY;
        sink->count -= 1;
        has_event = TRUE;
    }
    LeaveCriticalSection(&sink->lock);
    return has_event;
}

BOOL wind_event_sink_take_overflow(wind_event_sink *sink) {
    BOOL overflowed;
    if (sink == NULL) return FALSE;
    EnterCriticalSection(&sink->lock);
    overflowed = sink->overflowed;
    sink->overflowed = FALSE;
    LeaveCriticalSection(&sink->lock);
    return overflowed;
}
