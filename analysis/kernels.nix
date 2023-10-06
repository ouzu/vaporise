{pkgs, ...}: {
  kernel.python.python = {
    enable = true;
    extraPackages = ps: with ps;[
      numpy
      pandas
      scipy
      matplotlib
      seaborn
      numba
      scapy
      tqdm
      joblib
      ipywidgets
    ];
  };
}
