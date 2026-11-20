helper := $(MIX_APP_PATH)/priv/vm/vm-file

.PHONY: all clean
all: $(helper)

$(helper): vm-file.c Makefile
	mkdir -p "$(@D)"
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c11 -Wall -Wextra $(LDFLAGS) -o "$@" "$<"

clean:
	$(RM) "$(helper)"
