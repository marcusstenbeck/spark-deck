ROM := deck.nes

$(ROM): main.s nes.inc unrom512.cfg $(wildcard chr/* slides/*)
	ca65 -g main.s -o main.o
	ld65 -C unrom512.cfg --dbgfile deck.dbg -o $(ROM) main.o

clean:
	rm -f main.o deck.dbg $(ROM)

.PHONY: clean
