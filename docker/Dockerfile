FROM seeedcloud/pytorch:r35.2.1.1
RUN mkdir -p /var/lib/edge
COPY ./file/tegrastats /usr/bin/tegrastats
COPY ./SenseCraft-AI_Server/requirements.txt /usr/bin/edge/requirements.txt
COPY ./SenseCraft-AI_Server/models/ /var/lib/edge/models/
COPY ./SenseCraft-AI_Server/configs/ /var/lib/edge/configs/
COPY ./SenseCraft-AI_Server/src/ /usr/bin/edge/src/
COPY ./SenseCraft-AI_Server/sources/ /var/lib/edge/sources/
COPY ./run.sh /etc/init/run.sh
COPY ./SenseCraft-AI_Client/src-tauri/target/release/bundle/deb/sense-craft-ai_1.0.0_arm64.deb /usr/bin/sense-craft-ai_1.0.0_arm64.deb
RUN apt install /usr/bin/sense-craft-ai_1.0.0_arm64.deb
CMD bash /etc/init/run.sh