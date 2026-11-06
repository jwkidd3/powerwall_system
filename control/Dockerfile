# arb-controller — Plan B 740 controller (schedule + API), containerized.
# Runs on the controller Pi (same box as the pypowerwall proxy).
FROM python:3.12-slim-bookworm

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY arb_controller.py island_relay.py island_relay_sim.py ./

EXPOSE 8676
# Port is fixed inside the container; host networking publishes it on the LAN.
CMD ["uvicorn", "arb_controller:app", "--host", "0.0.0.0", "--port", "8676"]
