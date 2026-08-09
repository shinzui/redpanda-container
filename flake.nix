{
  description = "A local Redpanda cluster running on Apple Container, as a home-manager module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # Apple Container exists only on Apple Silicon macOS, so this flake deliberately
  # claims one system rather than pretending to be portable. A plain flake is used
  # instead of flake-parts: with one system and three outputs there is nothing for
  # flake-parts' per-system plumbing to simplify, and it would add an input to lock.
  outputs = { self, nixpkgs, home-manager }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      homeManagerModules.default = ./modules/home/redpanda-container.nix;
      homeManagerModules.redpanda-container = ./modules/home/redpanda-container.nix;

      # The five lifecycle wrappers, bundled so they can be built and exercised with
      # `nix build .#redpanda-scripts` without involving home-manager at all. This is
      # what makes the scripts independently verifiable before the module is wired up.
      packages.${system} = {
        redpanda-scripts = pkgs.symlinkJoin {
          name = "redpanda-scripts";
          paths = builtins.attrValues (import ./modules/home/scripts.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            cfg = import ./modules/home/defaults.nix { inherit pkgs; };
          });
        };
        default = self.packages.${system}.redpanda-scripts;
      };

      # A scratch home-manager configuration importing the module, so that
      # `nix build .#homeConfigurations.test.activationPackage` proves the module
      # composes without running darwin-rebuild switch on the real system.
      homeConfigurations.test = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          self.homeManagerModules.default
          {
            home = {
              username = "shinzui";
              homeDirectory = "/Users/shinzui";
              stateVersion = "24.05";
            };
            services.redpanda-container.enable = true;
          }
        ];
      };
    };
}
