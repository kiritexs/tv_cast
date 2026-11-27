#ifndef FLUTTER_PLUGIN_TV_CAST_PLUGIN_H_
#define FLUTTER_PLUGIN_TV_CAST_PLUGIN_H_

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
#include <string>

namespace tv_cast {

// Keeps Windows from sleeping by itself while a TV plays from this PC: the
// relay serves the TV, so the PC must stay awake.
class TvCastPlugin : public flutter::Plugin {
 public:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;

  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  explicit TvCastPlugin(std::unique_ptr<Channel> channel);

  virtual ~TvCastPlugin();

  TvCastPlugin(const TvCastPlugin &) = delete;
  TvCastPlugin &operator=(const TvCastPlugin &) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool Hold(const std::wstring &reason);
  void Release();

  std::unique_ptr<Channel> channel_;
  HANDLE request_ = nullptr;
  std::wstring reason_;
  bool held_ = false;
};

}  // namespace tv_cast

#endif  // FLUTTER_PLUGIN_TV_CAST_PLUGIN_H_
