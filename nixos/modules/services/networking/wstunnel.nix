{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.wstunnel;

  hostPortToString = { host, port }: "${host}:${toString port}";

  hostPortSubmodule = {
    options = {
      host = lib.mkOption {
        description = "The hostname.";
        type = lib.types.str;
      };
      port = lib.mkOption {
        description = "The port.";
        type = lib.types.port;
      };
    };
  };

  commonOptions = {
    enable = lib.mkEnableOption "this `wstunnel` instance" // {
      default = true;
    };

    package = lib.mkPackageOption pkgs "wstunnel" { };

    autoStart = lib.mkEnableOption "starting this wstunnel instance automatically" // {
      default = true;
    };

    extraArgs = lib.mkOption {
      description = ''
        Extra command line arguments to pass to `wstunnel`.
        Attributes of the form `argName = true;` will be translated to `--argName`,
        and `argName = \"value\"` to `--argName value`.
      '';
      type = with lib.types; attrsOf (either str bool);
      default = { };
      example = {
        "someNewOption" = true;
        "someNewOptionWithValue" = "someValue";
      };
    };

    # The original argument name `websocketPingFrequency` is a misnomer, as the frequency is the inverse of the interval.
    websocketPingInterval = lib.mkOption {
      description = "Frequency at which the client will send websocket ping to the server.";
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
    };

    loggingLevel = lib.mkOption {
      description = ''
        Passed to --log-lvl

        Control the log verbosity. i.e: TRACE, DEBUG, INFO, WARN, ERROR, OFF
        For more details, checkout [EnvFilter](https://docs.rs/tracing-subscriber/latest/tracing_subscriber/filter/struct.EnvFilter.html#example-syntax)
      '';
      type = lib.types.nullOr lib.types.str;
      example = "INFO";
      default = null;
    };

    environmentFile = lib.mkOption {
      description = ''
        Environment file to be passed to the systemd service.
        Useful for passing secrets to the service to prevent them from being
        world-readable in the Nix store.
        Note however that the secrets are passed to `wstunnel` through
        the command line, which makes them locally readable for all users of
        the system at runtime.
      '';
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/secrets/wstunnelSecrets";
    };
  };

  serverSubmodule =
    { config, ... }:
    {
      options = commonOptions // {
        listen = lib.mkOption {
          description = ''
            Address and port to listen on.
            Setting the port to a value below 1024 will also give the process
            the required `CAP_NET_BIND_SERVICE` capability.
          '';
          type = lib.types.submodule hostPortSubmodule;
          default = {
            host = "0.0.0.0";
            port = if config.enableHTTPS then 443 else 80;
          };
          defaultText = lib.literalExpression ''
            {
              host = "0.0.0.0";
              port = if enableHTTPS then 443 else 80;
            }
          '';
        };

        restrictTo = lib.mkOption {
          description = ''
            Accepted traffic will be forwarded only to this service.
          '';
          type = lib.types.listOf (lib.types.submodule hostPortSubmodule);
          default = [ ];
          example = [
            {
              host = "127.0.0.1";
              port = 51820;
            }
          ];
        };

        enableHTTPS = lib.mkOption {
          description = "Use HTTPS for the tunnel server.";
          type = lib.types.bool;
          default = true;
        };

        tlsCertificate = lib.mkOption {
          description = ''
            TLS certificate to use instead of the hardcoded one in case of HTTPS connections.
            Use together with `tlsKey`.
          '';
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = "/var/lib/secrets/cert.pem";
        };

        tlsKey = lib.mkOption {
          description = ''
            TLS key to use instead of the hardcoded on in case of HTTPS connections.
            Use together with `tlsCertificate`.
          '';
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = "/var/lib/secrets/key.pem";
        };

        useACMEHost = lib.mkOption {
          description = ''
            Use a certificate generated by the NixOS ACME module for the given host.
            Note that this will not generate a new certificate - you will need to do so with `security.acme.certs`.
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "example.com";
        };
      };
    };

  clientSubmodule =
    { config, ... }:
    {
      options = commonOptions // {
        connectTo = lib.mkOption {
          description = "Server address and port to connect to.";
          type = lib.types.str;
          example = "https://wstunnel.server.com:8443";
        };

        localToRemote = lib.mkOption {
          description = ''Listen on local and forwards traffic from remote.'';
          type = lib.types.listOf (lib.types.str);
          default = [ ];
          example = [
            "tcp://1212:google.com:443"
            "unix:///tmp/wstunnel.sock:g.com:443"
          ];
        };

        remoteToLocal = lib.mkOption {
          description = "Listen on remote and forwards traffic from local. Only tcp is supported";
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [
            "tcp://1212:google.com:443"
            "unix://wstunnel.sock:g.com:443"
          ];
        };

        addNetBind = lib.mkEnableOption "Whether add CAP_NET_BIND_SERVICE to the tunnel service, this should be enabled if you want to bind port < 1024";

        httpProxy = lib.mkOption {
          description = ''
            Proxy to use to connect to the wstunnel server (`USER:PASS@HOST:PORT`).

            ::: {.warning}
            Passwords specified here will be world-readable in the Nix store!
            To pass a password to the service, point the `environmentFile` option
            to a file containing `PROXY_PASSWORD=<your-password-here>` and set
            this option to `<user>:$PROXY_PASSWORD@<host>:<port>`.
            Note however that this will also locally leak the passwords at
            runtime via e.g. /proc/<pid>/cmdline.
            :::
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
        };

        soMark = lib.mkOption {
          description = ''
            Mark network packets with the SO_MARK sockoption with the specified value.
            Setting this option will also enable the required `CAP_NET_ADMIN` capability
            for the systemd service.
          '';
          type = lib.types.nullOr lib.types.ints.unsigned;
          default = null;
        };

        upgradePathPrefix = lib.mkOption {
          description = ''
            Use a specific HTTP path prefix that will show up in the upgrade
            request to the `wstunnel` server.
            Useful when running `wstunnel` behind a reverse proxy.
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "wstunnel";
        };

        tlsSNI = lib.mkOption {
          description = "Use this as the SNI while connecting via TLS. Useful for circumventing hostname-based firewalls.";
          type = lib.types.nullOr lib.types.str;
          default = null;
        };

        tlsVerifyCertificate = lib.mkOption {
          description = "Whether to verify the TLS certificate of the server. It might be useful to set this to `false` when working with the `tlsSNI` option.";
          type = lib.types.bool;
          default = true;
        };

        upgradeCredentials = lib.mkOption {
          description = ''
            Use these credentials to authenticate during the HTTP upgrade request
            (Basic authorization type, `USER:[PASS]`).

            ::: {.warning}
            Passwords specified here will be world-readable in the Nix store!
            To pass a password to the service, point the `environmentFile` option
            to a file containing `HTTP_PASSWORD=<your-password-here>` and set this
            option to `<user>:$HTTP_PASSWORD`.
            Note however that this will also locally leak the passwords at runtime
            via e.g. /proc/<pid>/cmdline.
            :::
          '';
          type = lib.types.nullOr lib.types.str;
          default = null;
        };

        customHeaders = lib.mkOption {
          description = "Custom HTTP headers to send during the upgrade request.";
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = {
            "X-Some-Header" = "some-value";
          };
        };
      };
    };

  generateServerUnit = name: serverCfg: {
    name = "wstunnel-server-${name}";
    value =
      let
        certConfig = config.security.acme.certs.${serverCfg.useACMEHost};
      in
      {
        description = "wstunnel server - ${name}";
        requires = [
          "network.target"
          "network-online.target"
        ];
        after = [
          "network.target"
          "network-online.target"
        ];
        wantedBy = lib.optional serverCfg.autoStart "multi-user.target";

        environment.RUST_LOG = serverCfg.loggingLevel;

        serviceConfig = {
          Type = "exec";
          EnvironmentFile = lib.optional (serverCfg.environmentFile != null) serverCfg.environmentFile;
          DynamicUser = true;
          SupplementaryGroups = lib.optional (serverCfg.useACMEHost != null) certConfig.group;
          PrivateTmp = true;
          AmbientCapabilities = lib.optionals (serverCfg.listen.port < 1024) [ "CAP_NET_BIND_SERVICE" ];
          NoNewPrivileges = true;
          RestrictNamespaces = "uts ipc pid user cgroup";
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          PrivateDevices = true;
          RestrictSUIDSGID = true;

          Restart = "on-failure";
          RestartSec = 2;
          RestartSteps = 20;
          RestartMaxDelaySec = "5min";
        };

        script = with serverCfg; ''
          ${lib.getExe package} \
            server \
            ${
              lib.cli.toGNUCommandLineShell { } (
                lib.recursiveUpdate {
                  restrict-to = map hostPortToString restrictTo;
                  tls-certificate =
                    if useACMEHost != null then "${certConfig.directory}/fullchain.pem" else "${tlsCertificate}";
                  tls-private-key = if useACMEHost != null then "${certConfig.directory}/key.pem" else "${tlsKey}";
                  websocket-ping-frequency-sec = websocketPingInterval;
                } extraArgs
              )
            } \
            ${lib.escapeShellArg "${if enableHTTPS then "wss" else "ws"}://${hostPortToString listen}"}
        '';
      };
  };

  generateClientUnit = name: clientCfg: {
    name = "wstunnel-client-${name}";
    value = {
      description = "wstunnel client - ${name}";
      requires = [
        "network.target"
        "network-online.target"
      ];
      after = [
        "network.target"
        "network-online.target"
      ];
      wantedBy = lib.optional clientCfg.autoStart "multi-user.target";

      environment.RUST_LOG = clientCfg.loggingLevel;

      serviceConfig = {
        Type = "exec";
        EnvironmentFile = lib.optional (clientCfg.environmentFile != null) clientCfg.environmentFile;
        DynamicUser = true;
        PrivateTmp = true;
        AmbientCapabilities =
          (lib.optionals clientCfg.addNetBind [ "CAP_NET_BIND_SERVICE" ])
          ++ (lib.optionals (clientCfg.soMark != null) [ "CAP_NET_ADMIN" ]);
        NoNewPrivileges = true;
        RestrictNamespaces = "uts ipc pid user cgroup";
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        PrivateDevices = true;
        RestrictSUIDSGID = true;

        Restart = "on-failure";
        RestartSec = 2;
        RestartSteps = 20;
        RestartMaxDelaySec = "5min";
      };

      script = with clientCfg; ''
        ${lib.getExe package} \
          client \
          ${
            lib.cli.toGNUCommandLineShell { } (
              lib.recursiveUpdate {
                local-to-remote = localToRemote;
                remote-to-local = remoteToLocal;
                http-headers = lib.mapAttrsToList (n: v: "${n}:${v}") customHeaders;
                http-proxy = httpProxy;
                socket-so-mark = soMark;
                http-upgrade-path-prefix = upgradePathPrefix;
                tls-sni-override = tlsSNI;
                tls-verify-certificate = tlsVerifyCertificate;
                websocket-ping-frequency-sec = websocketPingInterval;
                http-upgrade-credentials = upgradeCredentials;
              } extraArgs
            )
          } \
          ${lib.escapeShellArg connectTo}
      '';
    };
  };
in
{
  options.services.wstunnel = {
    enable = lib.mkEnableOption "wstunnel";

    servers = lib.mkOption {
      description = "`wstunnel` servers to set up.";
      type = lib.types.attrsOf (lib.types.submodule serverSubmodule);
      default = { };
      example = {
        "wg-tunnel" = {
          listen = {
            host = "0.0.0.0";
            port = 8080;
          };
          enableHTTPS = true;
          tlsCertificate = "/var/lib/secrets/fullchain.pem";
          tlsKey = "/var/lib/secrets/key.pem";
          restrictTo = [
            {
              host = "127.0.0.1";
              port = 51820;
            }
          ];
        };
      };
    };

    clients = lib.mkOption {
      description = "`wstunnel` clients to set up.";
      type = lib.types.attrsOf (lib.types.submodule clientSubmodule);
      default = { };
      example = {
        "wg-tunnel" = {
          connectTo = "wss://wstunnel.server.com:8443";
          localToRemote = [
            "tcp://1212:google.com:443"
            "tcp://2:n.lan:4?proxy_protocol"
          ];
          remoteToLocal = [
            "socks5://[::1]:1212"
            "unix://wstunnel.sock:g.com:443"
          ];
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services =
      (lib.mapAttrs' generateServerUnit (lib.filterAttrs (n: v: v.enable) cfg.servers))
      // (lib.mapAttrs' generateClientUnit (lib.filterAttrs (n: v: v.enable) cfg.clients));

    assertions =
      (lib.mapAttrsToList (name: serverCfg: {
        assertion = !(serverCfg.useACMEHost != null && serverCfg.tlsCertificate != null);
        message = ''
          Options services.wstunnel.servers."${name}".useACMEHost and services.wstunnel.servers."${name}".{tlsCertificate, tlsKey} are mutually exclusive.
        '';
      }) cfg.servers)
      ++

        (lib.mapAttrsToList (name: serverCfg: {
          assertion =
            (serverCfg.tlsCertificate == null && serverCfg.tlsKey == null)
            || (serverCfg.tlsCertificate != null && serverCfg.tlsKey != null);
          message = ''
            services.wstunnel.servers."${name}".tlsCertificate and services.wstunnel.servers."${name}".tlsKey need to be set together.
          '';
        }) cfg.servers)
      ++

        (lib.mapAttrsToList (name: clientCfg: {
          assertion = !(clientCfg.localToRemote == [ ] && clientCfg.remoteToLocal == [ ]);
          message = ''
            Either one of services.wstunnel.clients."${name}".localToRemote or services.wstunnel.clients."${name}".remoteToLocal must be set.
          '';
        }) cfg.clients);
  };

  meta.maintainers = with lib.maintainers; [
    alyaeanyx
    rvdp
    neverbehave
  ];
}
