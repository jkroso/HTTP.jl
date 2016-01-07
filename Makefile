server:
	gunicorn httpbin:app

.PHONY: server
