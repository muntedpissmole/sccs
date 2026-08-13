<h1>
  <img src="images/sccs-icon.svg" alt="SCCS" width="40" height="40" align="absmiddle" />
  The Singularity Camper Control System Interactive Demo
</h1>

## Install Service

Clone the repo, change the folder name to suit.

```bash
git clone -b demo https://github.com/muntedpissmole/sccs.git sccs-demo
cd sccs-demo
sudo ./install.sh --install
```

- UI: `http://<host>:5000/`

## Update

Pulls the latest `demo` branch, refreshes Python dependencies, and restarts the service. Keeps your existing `config/sccs.conf`.

```bash
cd sccs-demo
sudo ./install.sh --update
```

Or choose **Update** from the installer menu (`sudo ./install.sh`).

## Uninstall Service

```bash
sudo ./install.sh --uninstall
```

Stops and removes the service. Delete the folder manually with `rm -rf sccs-demo`.

## License

Licensed under the [MIT License](LICENSE).
