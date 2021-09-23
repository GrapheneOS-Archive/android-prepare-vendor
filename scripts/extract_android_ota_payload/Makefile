TARGETS := update_metadata_pb2.py

.PHONY: all clean
all: $(TARGETS)
clean:
	rm -f $(TARGETS)

%_pb2.py: %.proto
	protoc --python_out=. $<

update_metadata.proto:
	curl \
	https://android.googlesource.com/platform/system/update_engine/+/refs/heads/master/update_metadata.proto?format=TEXT | \
	base64 --decode > $@
