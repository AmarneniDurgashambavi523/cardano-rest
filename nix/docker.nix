############################################################################
# Docker image builder
#
# To build and load into the Docker engine:
#
#   docker load -i $(nix-build -A dockerImage.explorerApi --no-out-link)
#   docker load -i $(nix-build -A dockerImage.txSubmit --no-out-link)
#
# cardano-tx-submit
#  To launch with provided mainnet configuration
#
#    docker run -v /data -e NETWORK=mainnet inputoutput/cardano-tx-submit:<TAG>
#
#  To launch with provided testnet configuration
#
#    docker run -e NETWORK=testnet inputoutput/cardano-tx-submit:<TAG>
#
#  To launch with custom config, mount a dir containing config.json, genesis.json,
#  and topology.json into /config
#
#    docker run -v $PATH_TO/config:/config inputoutput/cardano-tx-submit:<TAG>
#
# cardano-explorer-api
#  docker run -v $PATH_TO/pgpass:/config/pgpass inputoutput/cardano-explorer-api:<TAG>
############################################################################

{ iohkNix
, commonLib
, dockerTools

# The main contents of the image.
, cardano-explorer-api
, cardano-tx-submit-webapi
, scripts

# Get the current commit
, gitrev ? iohkNix.commitIdFromGitRepoOrZero ../.git

# Other things to include in the image.
, bashInteractive
, cacert
, coreutils
, curl
, glibcLocales
, iana-etc
, iproute
, iputils
, socat
, utillinux
, writeScriptBin
, runtimeShell
, lib

, explorerApiRepoName ? "inputoutput/cardano-explorer-api"
, txSubmitRepoName ? "inputoutput/cardano-tx-submit"
}:

let

  # Layer of tools which aren't going to change much between versions.
  baseImage = dockerTools.buildImage {
    name = "base-env";
    contents = [
      bashInteractive   # Provide the BASH shell
      cacert            # X.509 certificates of public CA's
      coreutils         # Basic utilities expected in GNU OS's
      curl              # CLI tool for transferring files via URLs
      glibcLocales      # Locale information for the GNU C Library
      iana-etc          # IANA protocol and port number assignments
      iproute           # Utilities for controlling TCP/IP networking
      iputils           # Useful utilities for Linux networking
      socat             # Utility for bidirectional data transfer
      utillinux         # System utilities for Linux
    ];
    # set up /tmp (override with TMPDIR variable)
    extraCommands = ''
      mkdir -m 0777 tmp
    '';
  };
  explorerApiDockerImage = let
    entry-point = writeScriptBin "entry-point" ''
      #!${runtimeShell}
      #echo $NETWORK
      if [[ -d /config ]]; then
        echo PGPASSFILE = "/config/pgpass";
        exec ${cardano-explorer-api}/bin/cardano-explorer-api
      else
        echo "Please mount the pgpass file with credentials for postgres in /config"
      fi
    '';
  in dockerTools.buildImage {
    name = "${explorerApiRepoName}";
    fromImage = baseImage;
    tag = "${gitrev}";
    created = "now";   # Set creation date to build time. Breaks reproducibility
    contents = [ entry-point ];
    config = {
      EntryPoint = [ "${entry-point}/bin/entry-point" ];
      ExposedPorts = {
        "8100/tcp" = {};
      };
    };
  };
  txSubmitDockerImage = let
    clusterStatements = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: value: value) (commonLib.forEnvironments (env: ''
      elif [[ "$NETWORK" == "${env.name}" ]]; then
        exec ${scripts.${env.name}.tx-submit}
    '')));
    entry-point = writeScriptBin "entry-point" ''
      #!${runtimeShell}
      if [[ -d /config ]]; then
         exec ${cardano-tx-submit-webapi}/bin/cardano-tx-submit-webapi \
           --socket-path /data/node.socket \
           --genesis-file /config/genesis.json \
           --port 8101 \
           --config /data/config.yaml
      ${clusterStatements}
      else
        echo "Please set a NETWORK environment variable to one of: mainnet/testnet"
        echo "Or mount a /config volume containing: config.yaml and genesis.json"
      fi
    '';
  in dockerTools.buildImage {
    name = "${txSubmitRepoName}";
    fromImage = baseImage;
    tag = "${gitrev}";
    created = "now";   # Set creation date to build time. Breaks reproducibility
    contents = [ entry-point ];
    config = {
      EntryPoint = [ "${entry-point}/bin/entry-point" ];
      ExposedPorts = {
        "8101/tcp" = {};
      };
    };
  };

in {
  explorerApi = explorerApiDockerImage;
  txSubmit = txSubmitDockerImage;
}
