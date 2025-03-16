version: '3.8'

services:
  mdt-image-builder:
    image: mdt-image-builder:${TAG:-latest}
    build:
      context: .
      dockerfile: Dockerfile
    container_name: mdt-image-builder
    hostname: mdt-image-builder
    volumes:
      - ${WIM_CAPTURE_PATH:-C:/Temp/WIMCapture}:C:/Capture
      - ${CONFIG_PATH:-./config}:C:/Config
      - ${SCRIPTS_PATH:-./scripts}:C:/ImageBuilder/Scripts/Custom
      - ${RESOURCES_PATH:-./resources}:C:/ImageBuilder/Resources
    privileged: true
    isolation: hyperv
    restart: "no"
    environment:
      - WINDOWS_EDITION=${WINDOWS_EDITION:-Enterprise}
      - UPDATE_SOURCE=${UPDATE_SOURCE:-https://catalog.update.microsoft.com}
      - OFFICE365_CHANNEL=${OFFICE365_CHANNEL:-MonthlyEnterprise}
    entrypoint: ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File", "C:/ImageBuilder/MDT-BuildImage.ps1", "-EncodedParams", "${ENCODED_PARAMS}"]
