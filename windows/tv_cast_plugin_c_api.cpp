#include "include/tv_cast/tv_cast_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "tv_cast_plugin.h"

void TvCastPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  tv_cast::TvCastPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
