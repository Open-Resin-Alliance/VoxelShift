#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  const bool force_attach_console =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--attach-console") != command_line_arguments.end();
  const bool force_new_console =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--new-console") != command_line_arguments.end();

  // Attach to parent console when present (typical terminal launch), or
  // create a console for explicit flag/debugger flows.
  if (!AttachToParentConsole() && (force_attach_console || force_new_console || ::IsDebuggerPresent())) {
    CreateAndAttachConsole();
  }

  // Runner-only flags are consumed here and not forwarded to Dart.
  command_line_arguments.erase(
      std::remove_if(command_line_arguments.begin(), command_line_arguments.end(),
                     [](const std::string& arg) {
                       return arg == "--attach-console" || arg == "--new-console";
                     }),
      command_line_arguments.end());

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"voxelshift", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
