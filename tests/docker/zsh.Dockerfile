# Test environment for clh.zsh: zsh with curl and jq. The tools are GNU, not
# BSD, but tests and evals never run the generated commands. sw_vers is shimmed
# so _clh_context tells the model "macOS", as it does on a real Mac.
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends zsh curl jq ca-certificates procps perl git tmux bsdextrautils && rm -rf /var/lib/apt/lists/*
RUN printf '#!/bin/sh\ncase "$1" in\n  -productVersion) echo 15.5 ;;\n  *) printf "ProductName:\\tmacOS\\nProductVersion:\\t15.5\\n" ;;\nesac\n' > /usr/local/bin/sw_vers \
 && chmod +x /usr/local/bin/sw_vers
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
WORKDIR /clh
