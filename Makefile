CC = clang
CFLAGS = -Wall -Wextra -O2 -I/opt/homebrew/include
LDFLAGS = -L/opt/homebrew/lib -lusb-1.0 -lpthread

BIN = macdroid-tether-extreme

$(BIN): macdroid_tether_extreme.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

probe: probe.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(BIN) probe

.PHONY: clean
