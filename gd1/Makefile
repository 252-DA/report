MAIN = main
LATEX = pdflatex
BIBTEX = bibtex

.PHONY: all clean

all:
	$(LATEX) -shell-escape $(MAIN).tex
	$(BIBTEX) $(MAIN)
	$(LATEX) -shell-escape $(MAIN).tex
	$(LATEX) -shell-escape $(MAIN).tex

clean:
	rm -f *.aux *.log *.toc *.lof *.lot *.bbl *.blg *.out *.fls *.fdb_latexmk
	rm -f chapters/*.aux
	rm -f _minted-$(MAIN) -r

view:
	xdg-open $(MAIN).pdf &
