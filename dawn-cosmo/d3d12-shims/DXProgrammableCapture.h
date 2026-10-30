// stand-in for the Windows SDK header (PIX capture hooks): only the interface name Dawn mentions
#pragma once
#include <unknwn.h>
MIDL_INTERFACE("9f251514-9d4d-4902-9d60-18988ab7d4b5") IDXGraphicsAnalysis : public IUnknown {
  virtual void STDMETHODCALLTYPE BeginCapture() = 0;
  virtual void STDMETHODCALLTYPE EndCapture() = 0;
};
