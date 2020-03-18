FROM ubuntu:bionic

RUN sed -Ei 's/^# deb-src /deb-src /' /etc/apt/sources.list
RUN apt -yqq update --no-install-recommends >/dev/null && apt install -yqq --no-install-recommends curl schroot rsync tar xz-utils ca-certificates
