FROM fnproject/python:3.11-dev AS build-stage
WORKDIR /function
ENV PATH=/python/bin:$PATH
ADD requirements.txt /function/
RUN pip3 install --target /python --no-cache --no-cache-dir -r requirements.txt && rm -fr /root/.cache/pip requirements.txt func.yaml Dockerfile .dockerignore
ADD . /function/

FROM fnproject/python:3.11
WORKDIR /function
ENV PYTHONPATH=/python

COPY --from=build-stage /function /function
COPY --from=build-stage /python /python
RUN rm -fr /function/.pip_cache
ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
