# This simply extracts the POD so that github can display it

README.pod: osmgnuplot.pl
	podselect $^ > $@

clean:
	rm -rf README.pod
.PHONY: clean
