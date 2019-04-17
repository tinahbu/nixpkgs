{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.prometheus;
  cfg2 = config.services.prometheus2;
  promUser = "prometheus";
  promGroup = "prometheus";

  stateDir =
    if cfg.stateDir != null
    then cfg.stateDir
    else
      if cfg.dataDir != null
      then
        # This assumes /var/lib/ is a prefix of cfg.dataDir.
        # This is checked as an assertion below.
        removePrefix stateDirBase cfg.dataDir
      else "prometheus";
  stateDirBase = "/var/lib/";
  workingDir  = stateDirBase + stateDir;
  workingDir2 = stateDirBase + cfg2.stateDir;

  # a wrapper that verifies that the configuration is valid
  promtoolCheck = what: name: file: pkgs.runCommand "${name}-${what}-checked"
    { buildInputs = [ cfg.package ]; } ''
    ln -s ${file} $out
    promtool ${what} $out
  '';

  # a wrapper that verifies that the configuration is valid for
  # prometheus 2
  prom2toolCheck = what: name: file:
    pkgs.runCommand
      "${name}-${replaceStrings [" "] [""] what}-checked"
      { buildInputs = [ cfg2.package ]; } ''
    ln -s ${file} $out
    promtool ${what} $out
  '';

  # Pretty-print JSON to a file
  writePrettyJSON = name: x:
    pkgs.runCommand name { preferLocalBuild = true; } ''
      echo '${builtins.toJSON x}' | ${pkgs.jq}/bin/jq . > $out
    '';

  # This becomes the main config file for Prometheus 1
  promConfig = {
    global = filterValidPrometheus cfg.globalConfig;
    rule_files = map (promtoolCheck "check-rules" "rules") (cfg.ruleFiles ++ [
      (pkgs.writeText "prometheus.rules" (concatStringsSep "\n" cfg.rules))
    ]);
    scrape_configs = filterValidPrometheus cfg.scrapeConfigs;
  };

  generatedPrometheusYml = writePrettyJSON "prometheus.yml" promConfig;

  prometheusYml = let
    yml = if cfg.configText != null then
      pkgs.writeText "prometheus.yml" cfg.configText
      else generatedPrometheusYml;
    in promtoolCheck "check-config" "prometheus.yml" yml;

  cmdlineArgs = cfg.extraFlags ++ [
    "-storage.local.path=${workingDir}/metrics"
    "-config.file=${prometheusYml}"
    "-web.listen-address=${cfg.listenAddress}"
    "-alertmanager.notification-queue-capacity=${toString cfg.alertmanagerNotificationQueueCapacity}"
    "-alertmanager.timeout=${toString cfg.alertmanagerTimeout}s"
  ] ++
  optional (cfg.alertmanagerURL != []) "-alertmanager.url=${concatStringsSep "," cfg.alertmanagerURL}" ++
  optional (cfg.webExternalUrl != null) "-web.external-url=${cfg.webExternalUrl}";

  # This becomes the main config file for Prometheus 2
  promConfig2 = {
    global = filterValidPrometheus cfg2.globalConfig;
    rule_files = map (prom2toolCheck "check rules" "rules") (cfg2.ruleFiles ++ [
      (pkgs.writeText "prometheus.rules" (concatStringsSep "\n" cfg2.rules))
    ]);
    scrape_configs = filterValidPrometheus cfg2.scrapeConfigs;
    alerting = optionalAttrs (cfg2.alertmanagerURL != []) {
      alertmanagers = [{
        static_configs = [{
          targets = cfg2.alertmanagerURL;
        }];
      }];
    };
  };

  generatedPrometheus2Yml = writePrettyJSON "prometheus.yml" promConfig2;

  prometheus2Yml = let
    yml = if cfg2.configText != null then
      pkgs.writeText "prometheus.yml" cfg2.configText
      else generatedPrometheus2Yml;
    in prom2toolCheck "check config" "prometheus.yml" yml;

  cmdlineArgs2 = cfg2.extraFlags ++ [
    "--storage.tsdb.path=${workingDir2}/data/"
    "--config.file=${prometheus2Yml}"
    "--web.listen-address=${cfg2.listenAddress}"
    "--alertmanager.notification-queue-capacity=${toString cfg2.alertmanagerNotificationQueueCapacity}"
    "--alertmanager.timeout=${toString cfg2.alertmanagerTimeout}s"
  ] ++
  optional (cfg2.webExternalUrl != null) "--web.external-url=${cfg2.webExternalUrl}";

  filterValidPrometheus = filterAttrsListRecursive (n: v: !(n == "_module" || v == null));
  filterAttrsListRecursive = pred: x:
    if isAttrs x then
      listToAttrs (
        concatMap (name:
          let v = x.${name}; in
          if pred name v then [
            (nameValuePair name (filterAttrsListRecursive pred v))
          ] else []
        ) (attrNames x)
      )
    else if isList x then
      map (filterAttrsListRecursive pred) x
    else x;

  promTypes.globalConfig = types.submodule {
    options = {
      scrape_interval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          How frequently to scrape targets by default.
        '';
      };

      scrape_timeout = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          How long until a scrape request times out.
        '';
      };

      evaluation_interval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          How frequently to evaluate rules by default.
        '';
      };

      external_labels = mkOption {
        type = types.nullOr (types.attrsOf types.str);
        description = ''
          The labels to add to any time series or alerts when
          communicating with external systems (federation, remote
          storage, Alertmanager).
        '';
        default = null;
      };
    };
  };

  promTypes.scrape_config = types.submodule {
    options = {
      job_name = mkOption {
        type = types.str;
        description = ''
          The job name assigned to scraped metrics by default.
        '';
      };
      scrape_interval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          How frequently to scrape targets from this job. Defaults to the
          globally configured default.
        '';
      };
      scrape_timeout = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Per-target timeout when scraping this job. Defaults to the
          globally configured default.
        '';
      };
      metrics_path = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The HTTP resource path on which to fetch metrics from targets.
        '';
      };
      honor_labels = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = ''
          Controls how Prometheus handles conflicts between labels
          that are already present in scraped data and labels that
          Prometheus would attach server-side ("job" and "instance"
          labels, manually configured target labels, and labels
          generated by service discovery implementations).

          If honor_labels is set to "true", label conflicts are
          resolved by keeping label values from the scraped data and
          ignoring the conflicting server-side labels.

          If honor_labels is set to "false", label conflicts are
          resolved by renaming conflicting labels in the scraped data
          to "exported_&lt;original-label&gt;" (for example
          "exported_instance", "exported_job") and then attaching
          server-side labels. This is useful for use cases such as
          federation, where all labels specified in the target should
          be preserved.
        '';
      };
      scheme = mkOption {
        type = types.nullOr (types.enum ["http" "https"]);
        default = null;
        description = ''
          The URL scheme with which to fetch metrics from targets.
        '';
      };
      params = mkOption {
        type = types.nullOr (types.attrsOf (types.listOf types.str));
        default = null;
        description = ''
          Optional HTTP URL parameters.
        '';
      };
      basic_auth = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            username = mkOption {
              type = types.str;
              description = ''
                HTTP username
              '';
            };
            password = mkOption {
              type = types.str;
              description = ''
                HTTP password
              '';
            };
          };
        });
        default = null;
        description = ''
          Optional http login credentials for metrics scraping.
        '';
      };
      tls_config = mkOption {
        type = types.nullOr promTypes.tls_config;
        default = null;
        description = ''
          Configures the scrape request's TLS settings.
        '';
      };
      dns_sd_configs = mkOption {
        type = types.nullOr (types.listOf promTypes.dns_sd_config);
        default = null;
        description = ''
          List of DNS service discovery configurations.
        '';
      };
      consul_sd_configs = mkOption {
        type = types.nullOr (types.listOf promTypes.consul_sd_config);
        default = null;
        description = ''
          List of Consul service discovery configurations.
        '';
      };
      file_sd_configs = mkOption {
        type = types.nullOr (types.listOf promTypes.file_sd_config);
        default = null;
        description = ''
          List of file service discovery configurations.
        '';
      };
      static_configs = mkOption {
        type = types.nullOr (types.listOf promTypes.static_config);
        default = null;
        description = ''
          List of labeled target groups for this job.
        '';
      };
      ec2_sd_configs = mkOption {
        type = types.nullOr (types.listOf promTypes.ec2_sd_config);
        default = null;
        description = ''
          List of EC2 service discovery configurations.
        '';
      };
      relabel_configs = mkOption {
        type = types.nullOr (types.listOf promTypes.relabel_config);
        default = null;
        description = ''
          List of relabel configurations.
        '';
      };
    };
  };

  promTypes.static_config = types.submodule {
    options = {
      targets = mkOption {
        type = types.listOf types.str;
        description = ''
          The targets specified by the target group.
        '';
      };
      labels = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = ''
          Labels assigned to all metrics scraped from the targets.
        '';
      };
    };
  };

  promTypes.ec2_sd_config = types.submodule {
    options = {
      region = mkOption {
        type = types.str;
        description = ''
          The AWS Region.
        '';
      };
      endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Custom endpoint to be used.
        '';
      };
      access_key = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The AWS API key id. If blank, the environment variable
          <literal>AWS_ACCESS_KEY_ID</literal> is used.
        '';
      };
      secret_key = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The AWS API key secret. If blank, the environment variable
           <literal>AWS_SECRET_ACCESS_KEY</literal> is used.
        '';
      };
      profile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Named AWS profile used to connect to the API.
        '';
      };
      role_arn = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          AWS Role ARN, an alternative to using AWS API keys.
        '';
      };
      refresh_interval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Refresh interval to re-read the instance list.
        '';
      };
      port = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          The port to scrape metrics from. If using the public IP
          address, this must instead be specified in the relabeling
          rule.
        '';
      };
      filters = mkOption {
        type = types.nullOr (types.listOf promTypes.filter);
        default = null;
        description = ''
          Filters can be used optionally to filter the instance list by other criteria.
        '';
      };
    };
  };

  promTypes.filter = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = ''
          See <link xlink:href="https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DescribeInstances.html">this list</link>
          for the available filters.
        '';
      };
      value = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Value of the filter.
        '';
      };
    };
  };

  promTypes.dns_sd_config = types.submodule {
    options = {
      names = mkOption {
        type = types.listOf types.str;
        description = ''
          A list of DNS SRV record names to be queried.
        '';
      };
      refresh_interval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The time after which the provided names are refreshed.
        '';
      };
    };
  };

  promTypes.consul_sd_config = types.submodule {
    options = {
      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Consul server to query.";
      };
      token = mkOption {
        type = types.nullOr types.str;
        description = "Consul token";
      };
      datacenter = mkOption {
        type = types.nullOr types.str;
        description = "Consul datacenter";
      };
      scheme = mkOption {
        type = types.nullOr types.str;
        description = "Consul scheme";
      };
      username = mkOption {
        type = types.nullOr types.str;
        description = "Consul username";
      };
      password = mkOption {
        type = types.nullOr types.str;
        description = "Consul password";
      };

      services = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          A list of services for which targets are retrieved.
        '';
      };
      tag_separator = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The string by which Consul tags are joined into the tag label.
        '';
      };
    };
  };

  promTypes.file_sd_config = types.submodule {
    options = {
      files = mkOption {
        type = types.listOf types.str;
        description = ''
          Patterns for files from which target groups are extracted. Refer
          to the Prometheus documentation for permitted filename patterns
          and formats.
        '';
      };
      refresh_interval = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Refresh interval to re-read the files.
        '';
      };
    };
  };

  promTypes.relabel_config = types.submodule {
    options = {
      source_labels = mkOption {
        type = types.nullOr (types.listOf str);
        default = null;
        description = ''
          The source labels select values from existing labels. Their content
          is concatenated using the configured separator and matched against
          the configured regular expression.
        '';
      };
      separator = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Separator placed between concatenated source label values.
        '';
      };
      target_label = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Label to which the resulting value is written in a replace action.
          It is mandatory for replace actions.
        '';
      };
      regex = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Regular expression against which the extracted value is matched.
        '';
      };
      replacement = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Replacement value against which a regex replace is performed if the
          regular expression matches.
        '';
      };
      action = mkOption {
        type = types.nullOr (types.enum ["replace" "keep" "drop"]);
        default = null;
        description = ''
          Action to perform based on regex matching.
        '';
      };
    };
  };

  promTypes.tls_config = types.submodule {
    options = {
      ca_file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          CA certificate to validate API server certificate with.
        '';
      };
      cert_file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Certificate file for client cert authentication to the server.
        '';
      };
      key_file = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Key file for client cert authentication to the server.
        '';
      };
      server_name = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          ServerName extension to indicate the name of the server.
          http://tools.ietf.org/html/rfc4366#section-3.1
        '';
      };
      insecure_skip_verify = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Disable validation of the server certificate.
        '';
      };
    };
  };

in {
  options = {
    services.prometheus = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the Prometheus monitoring daemon.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.prometheus;
        defaultText = "pkgs.prometheus";
        description = ''
          The prometheus package that should be used.
        '';
      };

      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0:9090";
        description = ''
          Address to listen on for the web interface, API, and telemetry.
        '';
      };

      dataDir = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Directory to store Prometheus metrics data.
          This option is deprecated, please use <option>services.prometheus.stateDir</option>.
        '';
      };

      stateDir = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Directory below <literal>${stateDirBase}</literal> to store Prometheus metrics data.
          This directory will be created automatically using systemd's StateDirectory mechanism.
          Defaults to <literal>prometheus</literal>.
        '';
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Extra commandline options when launching Prometheus.
        '';
      };

      configText = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = ''
          If non-null, this option defines the text that is written to
          prometheus.yml. If null, the contents of prometheus.yml is generated
          from the structured config options.
        '';
      };

      globalConfig = mkOption {
        type = promTypes.globalConfig;
        default = {};
        description = ''
          Parameters that are valid in all  configuration contexts. They
          also serve as defaults for other configuration sections
        '';
      };

      rules = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Alerting and/or Recording rules to evaluate at runtime.
        '';
      };

      ruleFiles = mkOption {
        type = types.listOf types.path;
        default = [];
        description = ''
          Any additional rules files to include in this configuration.
        '';
      };

      scrapeConfigs = mkOption {
        type = types.listOf promTypes.scrape_config;
        default = [];
        description = ''
          A list of scrape configurations.
        '';
      };

      alertmanagerURL = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          List of Alertmanager URLs to send notifications to.
        '';
      };

      alertmanagerNotificationQueueCapacity = mkOption {
        type = types.int;
        default = 10000;
        description = ''
          The capacity of the queue for pending alert manager notifications.
        '';
      };

      alertmanagerTimeout = mkOption {
        type = types.int;
        default = 10;
        description = ''
          Alert manager HTTP API timeout (in seconds).
        '';
      };

      webExternalUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://example.com/";
        description = ''
          The URL under which Prometheus is externally reachable (for example,
          if Prometheus is served via a reverse proxy).
        '';
      };
    };
    services.prometheus2 = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the Prometheus 2 monitoring daemon.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.prometheus_2;
        defaultText = "pkgs.prometheus_2";
        description = ''
          The prometheus2 package that should be used.
        '';
      };

      listenAddress = mkOption {
        type = types.str;
        default = "0.0.0.0:9090";
        description = ''
          Address to listen on for the web interface, API, and telemetry.
        '';
      };

      stateDir = mkOption {
        type = types.str;
        default = "prometheus2";
        description = ''
          Directory below <literal>${stateDirBase}</literal> to store Prometheus metrics data.
          This directory will be created automatically using systemd's StateDirectory mechanism.
          Defaults to <literal>prometheus2</literal>.
        '';
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Extra commandline options when launching Prometheus 2.
        '';
      };

      configText = mkOption {
        type = types.nullOr types.lines;
        default = null;
        description = ''
          If non-null, this option defines the text that is written to
          prometheus.yml. If null, the contents of prometheus.yml is generated
          from the structured config options.
        '';
      };

      globalConfig = mkOption {
        type = promTypes.globalConfig;
        default = {};
        description = ''
          Parameters that are valid in all  configuration contexts. They
          also serve as defaults for other configuration sections
        '';
      };

      rules = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          Alerting and/or Recording rules to evaluate at runtime.
        '';
      };

      ruleFiles = mkOption {
        type = types.listOf types.path;
        default = [];
        description = ''
          Any additional rules files to include in this configuration.
        '';
      };

      scrapeConfigs = mkOption {
        type = types.listOf promTypes.scrape_config;
        default = [];
        description = ''
          A list of scrape configurations.
        '';
      };

      alertmanagerURL = mkOption {
        type = types.listOf types.str;
        default = [];
        description = ''
          List of Alertmanager URLs to send notifications to.
        '';
      };

      alertmanagerNotificationQueueCapacity = mkOption {
        type = types.int;
        default = 10000;
        description = ''
          The capacity of the queue for pending alert manager notifications.
        '';
      };

      alertmanagerTimeout = mkOption {
        type = types.int;
        default = 10;
        description = ''
          Alert manager HTTP API timeout (in seconds).
        '';
      };

      webExternalUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://example.com/";
        description = ''
          The URL under which Prometheus is externally reachable (for example,
          if Prometheus is served via a reverse proxy).
        '';
      };
    };
   };

  config = mkMerge [
    (mkIf (cfg.enable || cfg2.enable) {
      users.groups.${promGroup}.gid = config.ids.gids.prometheus;
      users.users.${promUser} = {
        description = "Prometheus daemon user";
        uid = config.ids.uids.prometheus;
        group = promGroup;
      };
    })
    (mkIf cfg.enable {
      warnings =
        optional (cfg.dataDir != null) ''
          The option services.prometheus.dataDir is deprecated, please use
          services.prometheus.stateDir.
        '';
      assertions = [
        {
          assertion = !(cfg.dataDir != null && cfg.stateDir != null);
          message =
            "The options services.prometheus.dataDir and services.prometheus.stateDir" +
            " can't both be set at the same time! It's recommended to only set the latter" +
            " since the former is deprecated.";
        }
        {
          assertion = cfg.dataDir != null -> hasPrefix stateDirBase cfg.dataDir;
          message =
            "The option services.prometheus.dataDir should have ${stateDirBase} as a prefix!";
        }
        {
          assertion = cfg.stateDir != null -> !hasPrefix "/" cfg.stateDir;
          message =
            "The option services.prometheus.stateDir shouldn't be an absolute directory." +
            " It should be a directory relative to ${stateDirBase}.";
        }
        {
          assertion = cfg2.stateDir != null -> !hasPrefix "/" cfg2.stateDir;
          message =
            "The option services.prometheus2.stateDir shouldn't be an absolute directory." +
            " It should be a directory relative to ${stateDirBase}.";
        }
      ];
      systemd.services.prometheus = {
        wantedBy = [ "multi-user.target" ];
        after    = [ "network.target" ];
        serviceConfig = {
          ExecStart = "${cfg.package}/bin/prometheus" +
            optionalString (length cmdlineArgs != 0) (" \\\n  " +
              concatStringsSep " \\\n  " cmdlineArgs);
          User = promUser;
          Restart  = "always";
          WorkingDirectory = workingDir;
          StateDirectory = stateDir;
        };
      };
    })
    (mkIf cfg2.enable {
      systemd.services.prometheus2 = {
        wantedBy = [ "multi-user.target" ];
        after    = [ "network.target" ];
        serviceConfig = {
          ExecStart = "${cfg2.package}/bin/prometheus" +
            optionalString (length cmdlineArgs2 != 0) (" \\\n  " +
              concatStringsSep " \\\n  " cmdlineArgs2);
          User = promUser;
          Restart  = "always";
          WorkingDirectory = workingDir2;
          StateDirectory = cfg2.stateDir;
        };
      };
    })
  ];
}
