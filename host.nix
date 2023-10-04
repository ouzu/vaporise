{ pkgs, config, lib, ... }: {
  security.sudo.wheelNeedsPassword = false;
  users.extraUsers.user = {
    isNormalUser = true;
    createHome = true;
    home = "/home/user";
    group = "users";
    extraGroups = [ "wheel" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMO2GDOWjN3sWSCS6gN+e8gT4IiALNxCBvC8dZTzjTbq" ];
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  programs.zsh.enable = true;
  programs.starship.enable = true;
  programs.fzf.keybindings = true;
  programs.mosh.enable = true;

  environment.systemPackages = with pkgs; [
    git
    helix
    xh
    btop
    tmux
    iptables
  ];
}
