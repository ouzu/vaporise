{ pkgs, config, lib, ... }: {
  security.sudo.wheelNeedsPassword = false;
  users.extraUsers.user = {
    isNormalUser = true;
    createHome = true;
    home = "/home/user";
    group = "users";
    extraGroups = [ "wheel" ];
    useDefaultShell = true;
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMO2GDOWjN3sWSCS6gN+e8gT4IiALNxCBvC8dZTzjTbq" ];
  };
}
