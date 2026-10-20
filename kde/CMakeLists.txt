cmake_minimum_required(VERSION 3.24)
project(niche-kde VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(ECM 6.0 REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
include(KDEInstallDirs)
include(ECMQmlModule)

find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui Widgets Qml Quick QuickControls2 DBus Network Concurrent WaylandClient)
find_package(KF6 REQUIRED COMPONENTS StatusNotifierItem GlobalAccel GuiAddons)
find_package(LayerShellQt REQUIRED)
find_package(PlasmaWaylandProtocols REQUIRED)
find_package(Wayland REQUIRED COMPONENTS Client)
find_package(PkgConfig REQUIRED)
pkg_check_modules(PULSE REQUIRED IMPORTED_TARGET libpulse libpulse-mainloop-glib)

qt_standard_project_setup(REQUIRES 6.8)

# Runtime search paths baked into the binary (the nix build passes them; a dev
# shell exports them as environment variables).
set(NICHE_PLUGIN_PATH "$ENV{NICHE_PLUGIN_PATH}" CACHE STRING "Qt plugin dirs prepended at startup")
set(NICHE_QML_PATH "$ENV{NICHE_QML_PATH}" CACHE STRING "QML import dirs prepended at startup")

file(GLOB_RECURSE NICHE_SOURCES CONFIGURE_DEPENDS src/*.cpp src/*.h)
file(GLOB_RECURSE NICHE_QML RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS qml/*.qml)
file(GLOB_RECURSE NICHE_ASSETS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS assets/*)

qt_add_executable(niche-kde ${NICHE_SOURCES})

ecm_add_wayland_client_protocol(niche-kde
    PROTOCOL ${PLASMA_WAYLAND_PROTOCOLS_DIR}/fake-input.xml
    BASENAME fake-input)

foreach(file IN LISTS NICHE_QML)
    get_filename_component(name ${file} NAME_WE)
    if(name STREQUAL "Metrics")
        set_source_files_properties(${file} PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
    endif()
endforeach()

qt_add_qml_module(niche-kde
    URI Niche
    VERSION 1.0
    QML_FILES ${NICHE_QML}
    RESOURCES ${NICHE_ASSETS}
    NO_PLUGIN_OPTIONAL
)

target_compile_definitions(niche-kde PRIVATE
    NICHE_VERSION="${PROJECT_VERSION}"
    NICHE_PLUGIN_PATH="${NICHE_PLUGIN_PATH}"
    NICHE_QML_PATH="${NICHE_QML_PATH}"
)

target_include_directories(niche-kde PRIVATE src ${CMAKE_CURRENT_BINARY_DIR})

target_link_libraries(niche-kde PRIVATE
    Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Qml Qt6::Quick Qt6::QuickControls2 Qt6::DBus
    Qt6::Network Qt6::Concurrent Qt6::WaylandClient
    KF6::StatusNotifierItem KF6::GlobalAccel KF6::GuiAddons
    LayerShellQt::Interface
    Wayland::Client
    PkgConfig::PULSE
)

install(TARGETS niche-kde RUNTIME DESTINATION ${KDE_INSTALL_BINDIR})
# KWin grants org_kde_kwin_fake_input (paste on pick) by matching Exec against
# the running executable, so Exec must be the absolute installed path.
set(NICHE_EXEC "${KDE_INSTALL_FULL_BINDIR}/niche-kde")
configure_file(data/org.niche.Island.desktop.in ${CMAKE_CURRENT_BINARY_DIR}/org.niche.Island.desktop @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/org.niche.Island.desktop DESTINATION ${KDE_INSTALL_APPDIR})
install(FILES assets/icon.png DESTINATION ${KDE_INSTALL_DATADIR}/icons/hicolor/256x256/apps RENAME niche-kde.png)
