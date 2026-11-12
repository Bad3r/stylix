{
  mkTarget,
  pkgs,
  config,
  lib,
  nixosConfig ? null,
  ...
}:
let
  qtctSettings = attrs: {
    qt5ctSettings = lib.mkIf (config.qt.platformTheme.name == "qtct") attrs;
    qt6ctSettings = lib.mkIf (config.qt.platformTheme.name == "qtct") attrs;
  };

  # Light, Midlight, Mid, and Dark derived from Button (base02) as
  # QPalette(button, window) does, so the shade ramp hugs Button on any
  # scheme instead of jumping to the base03/base04 foreground tones.
  # Ports QColor::lighter/darker (16-bit HSV round trip) and
  # qt_mix_colors, so the values match Qt's own derivation.
  qtShades =
    colors:
    let
      round = x: builtins.floor (x + 0.5);
      toUnit = c: c * 257 / 65535.0;
      toByte = word: round (word / 257.0);
      button = map (c: lib.toInt colors."base02-rgb-${c}") (
        lib.stringToCharacters "rgb"
      );

      scale =
        scaleValue: rgb:
        let
          channels = map toUnit rgb;
          r = builtins.elemAt channels 0;
          g = builtins.elemAt channels 1;
          b = builtins.elemAt channels 2;
          max = lib.foldl' lib.max 0.0 channels;
          delta = max - lib.foldl' lib.min 1.0 channels;
          hueSector =
            if r == max then
              (g - b) / delta
            else if g == max then
              2 + (b - r) / delta
            else
              4 + (r - g) / delta;
          hueDegrees = hueSector * 60;
          hue = round ((if hueDegrees < 0 then hueDegrees + 360 else hueDegrees) * 100);
          saturation = round (delta / max * 65535);
          scaled = scaleValue (round (max * 65535));
          s = lib.max 0 (saturation - lib.max 0 (scaled - 65535)) / 65535.0;
          value = lib.min scaled 65535;
          v = value / 65535.0;
          h = if hue == 36000 then 0.0 else hue / 6000.0;
          i = builtins.floor h;
          f = h - i;
          components = {
            inherit v;
            p = v * (1 - s);
            q = v * (1 - s * f);
            t = v * (1 - s * (1 - f));
          };
        in
        if delta == 0 || s == 0 then
          lib.replicate 3 (toByte value)
        else
          map (n: toByte (round (components.${n} * 65535))) (
            lib.stringToCharacters (builtins.substring (i * 3) 3 "vtpqvppvtpqvtpvvpq")
          );

      lighter = factor: scale (v: factor * v / 100);
      darker = factor: scale (v: v * 100 / factor);
      toHex =
        rgb:
        "#"
        + lib.concatMapStrings (
          c: lib.fixedWidthString 2 "0" (lib.toLower (lib.toHexString c))
        ) rgb;
      light = lighter 150 button;
    in
    lib.mapAttrs (_: toHex) {
      inherit light;
      midlight = lib.zipListsWith (a: b: (a + b) / 2) button light;
      mid = darker 150 button;
      dark = darker 200 button;
    };
in
mkTarget {
  # TODO: Replace `nixosConfig != null` with
  # `pkgs.stdenv.hostPlatform.isLinux` once [1] ("bug: setting qt.style.name
  # = kvantum makes host systemd unusable") is resolved.
  #
  # [1]: https://github.com/nix-community/home-manager/issues/6565
  autoEnable = nixosConfig != null;
  autoEnableExpr = "nixosConfig != null";

  options = {
    platform = lib.mkOption {
      description = ''
        Selects the platform theme to use for Qt applications.

        Defaults to the standard platform theme used in the configured DE in NixOS when
        `stylix.homeManagerIntegration.followSystem = true`.
      '';
      type = lib.types.str;
      default = "qtct";
    };

    standardDialogs = lib.mkOption {
      description = ''
        Selects the standard dialogs theme to be used by Qt.

        Using `xdgdesktopportal` integrates with the native desktop portal.
      '';

      # The enum variants are derived from the qt6ct platform theme integration
      # [1].
      #
      # [1]: https://www.opencode.net/trialuser/qt6ct/-/blob/00823e41aa60e8fe266d5aee328e82ad1ad94348/src/qt6ct/appearancepage.cpp#L83-L92
      type = lib.types.enum [
        "default"
        "gtk2"
        "gtk3"
        "kde"
        "xdgdesktopportal"
      ];

      default = "default";
    };

    recommendedStyles.gnome = lib.mkOption {
      internal = true;
      type = lib.types.singleLineStr;
      default = "adwaita";
    };
  };

  config = [
    (
      { cfg }:
      let
        recommendedStyles = {
          gnome = cfg.recommendedStyles.gnome;
          kde = "breeze";
          qtct = "kvantum";
        };

        recommendedStyle = recommendedStyles."${config.qt.platformTheme.name}" or null;
      in
      {
        warnings =
          lib.optional (cfg.platform != "qtct")
            "stylix: qt: `config.stylix.targets.qt.platform` other than 'qtct' are currently unsupported: ${cfg.platform}. Support may be added in the future."

          ++
            lib.optional (config.qt.style.name != recommendedStyle)
              "stylix: qt: Changing `config.qt.style` is unsupported and may result in breakage! Use with caution!";

        qt = lib.mkMerge [
          {
            enable = true;
            style.name = recommendedStyle;
            platformTheme.name = cfg.platform;
          }
          (qtctSettings {
            Appearance = {
              custom_palette = true;
              standard_dialogs = cfg.standardDialogs;
              style = lib.mkIf (config.qt.style ? name) config.qt.style.name;
            };
          })
        ];
      }
    )
    (
      { polarity }:
      {
        stylix.targets.qt.recommendedStyles.gnome =
          if polarity == "dark" then "adwaita-dark" else "adwaita";
      }
    )
    (
      { colors }:
      let
        kvantumPackage =
          let
            kvconfig = colors {
              template = ./kvconfig.mustache;
              extension = ".kvconfig";
            };
            svg = colors {
              template = ./kvantum.svg.mustache;
              extension = ".svg";
            };
          in
          pkgs.runCommandLocal "base16-kvantum" { } ''
            directory="$out/share/Kvantum/Base16Kvantum"
            mkdir --parents "$directory"
            substitute ${kvconfig} "$directory/Base16Kvantum.kvconfig" \
              ${lib.concatStringsSep " " (
                lib.mapAttrsToList (
                  name: value: "--replace-fail @${name}@ ${lib.escapeShellArg value}"
                ) (qtShades colors)
              )}
            cp ${svg} "$directory/Base16Kvantum.svg"
          '';
      in
      {
        qt.kvantum = lib.mkIf (config.qt.style.name == "kvantum") {
          enable = true;
          settings.General.theme = "Base16Kvantum";
          themes = [ kvantumPackage ];
        };
      }
    )
    (
      { icons, polarity }:
      let
        iconTheme = if polarity == "dark" then icons.dark else icons.light;
      in
      {
        qt = qtctSettings {
          Appearance.icon_theme = lib.mkIf (iconTheme != null) iconTheme;
        };
      }
    )
    (
      { fonts }:
      {
        qt = qtctSettings {
          Fonts = {
            fixed = ''"${fonts.monospace.name},${toString fonts.sizes.applications}"'';
            general = ''"${fonts.sansSerif.name},${toString fonts.sizes.applications}"'';
          };
        };
      }
    )
    (
      { colors }:
      let
        palette = colors.withHashtag;
        shades = qtShades colors;

        # QPalette::ColorRole order 0..20. qt6ct's parser iterates the
        # enum directly. Accent (21, Qt 6.6+) is auto-filled from
        # Highlight by qt6ct when the row has 21 entries, so omitting it
        # is forward-compatible. Roles overlapping kvconfig.mustache use
        # the same value to keep mixed Kvantum + QtQuick UIs
        # visually consistent.
        activePaletteRoles = [
          palette.base05 # 0  WindowText      (kvconfig: window.text.color)
          palette.base02 # 1  Button          (kvconfig: button.color)
          shades.light # 2  Light
          shades.midlight # 3  Midlight
          shades.dark # 4  Dark
          shades.mid # 5  Mid
          palette.base05 # 6  Text            (kvconfig: text.color)
          palette.base07 # 7  BrightText      (Qt high-contrast Text fallback)
          palette.base05 # 8  ButtonText      (kvconfig: button.text.color)
          palette.base00 # 9  Base            (kvconfig: base.color)
          palette.base01 # 10 Window          (kvconfig: window.color)
          shades.dark # 11 Shadow
          palette.base0E # 12 Highlight       (kvconfig: highlight.color)
          # HighlightedText diverges from kvconfig.mustache (base00):
          # on schemes where Highlight (base0E) and Window (base01)
          # collapse toward similar luminance, base00 makes selected
          # text unreadable. base05 keeps high contrast against any
          # Highlight choice.
          palette.base05 # 13 HighlightedText
          palette.base0D # 14 Link            (kvconfig: link.color)
          palette.base0E # 15 LinkVisited     (kvconfig: link.visited.color)
          palette.base01 # 16 AlternateBase   (kvconfig: alt.base.color)
          palette.base00 # 17 NoRole
          palette.base00 # 18 ToolTipBase    (kvconfig: tooltip.base.color)
          palette.base05 # 19 ToolTipText     (kvconfig: tooltip.text.color)
          palette.base04 # 20 PlaceholderText
        ];

        # Inactive: only Highlight differs (base03), matching kvconfig
        # `inactive.highlight.color`.
        inactivePaletteRoles = lib.imap0 (
          i: v: if i == 12 then palette.base03 else v
        ) activePaletteRoles;

        # Disabled: foregrounds and accent collapse to muted base02..base04;
        # backgrounds and shade ramp match active to preserve silhouette.
        # Without a distinct disabled row, Qt no longer auto-greys widgets
        # under a custom palette, so disabled controls would render
        # identical to enabled ones.
        disabledPaletteRoles = [
          palette.base04 # 0  WindowText
          palette.base02 # 1  Button
          shades.light # 2  Light
          shades.midlight # 3  Midlight
          shades.dark # 4  Dark
          shades.mid # 5  Mid
          palette.base04 # 6  Text
          palette.base04 # 7  BrightText
          palette.base04 # 8  ButtonText
          palette.base00 # 9  Base
          palette.base01 # 10 Window
          shades.dark # 11 Shadow
          palette.base02 # 12 Highlight
          palette.base04 # 13 HighlightedText
          palette.base04 # 14 Link
          palette.base04 # 15 LinkVisited
          palette.base01 # 16 AlternateBase
          palette.base00 # 17 NoRole
          palette.base00 # 18 ToolTipBase
          palette.base04 # 19 ToolTipText
          palette.base03 # 20 PlaceholderText
        ];

        toArgb = c: "#ff${lib.removePrefix "#" c}";
        formatRow = colours: lib.concatStringsSep ", " (map toArgb colours);

        schemeText = ''
          [ColorScheme]
          active_colors=${formatRow activePaletteRoles}
          inactive_colors=${formatRow inactivePaletteRoles}
          disabled_colors=${formatRow disabledPaletteRoles}
        '';
      in
      {
        qt = lib.mkIf (config.qt.platformTheme.name == "qtct") {
          qt5ctSettings.Appearance.color_scheme_path = "${config.xdg.configHome}/qt5ct/colors/stylix.conf";
          qt6ctSettings.Appearance.color_scheme_path = "${config.xdg.configHome}/qt6ct/colors/stylix.conf";
        };

        xdg.configFile = lib.mkIf (config.qt.platformTheme.name == "qtct") {
          "qt5ct/colors/stylix.conf".text = schemeText;
          "qt6ct/colors/stylix.conf".text = schemeText;
        };
      }
    )
  ];
}
