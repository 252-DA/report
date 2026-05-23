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
	rm -f chapters/*.aux frontmatter/*.aux appendix/*.aux
	rm -rf _minted-$(MAIN)

view:
	xdg-open $(MAIN).pdf &
