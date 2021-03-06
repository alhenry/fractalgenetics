###############################
### Libraries and functions ###
###############################
options(import.path="/homes/hannah/projects/GWAS")
options(bitmapType = 'cairo', device = 'pdf')

modules::import_package('ggplot2', attach=TRUE)
modules::import_package('grid', attach=TRUE)
modules::import_package('dplyr', attach=TRUE)

optparse <- modules::import_package('optparse')
garfield <- modules::import_package('garfield')
zip <- modules::import_package('zip')
prepGarfield <- modules::import("prepGarfield")

## functions ####
prepAnalyses <- function(traitindex, bgenie, directory,
                             garfielddir=paste("/nfs/research1/birney/",
                                               "resources/human_reference/",
                                               "GARFIELD/garfield-data", sep=""),
                             is.NegLog10=TRUE,
                             annotations="1-1005"){
    trait_name <- gsub("-log10p", "", colnames(bgenie)[traitindex])
    gwas <- bgenie[, c(1:3, traitindex)]
    colnames(gwas)[4] <- "P"
    if (is.NegLog10) gwas$P <- 10^(-gwas$P)
    resdir <- paste(directory, "/", trait_name, sep="")

    message("Prepare Garfield files for trait: ", trait_name)
    garfieldPrep <- prepGarfield$prepGarfield(gwas=gwas,
            trait_name=trait_name, directory=directory,
            chr_name="chr", bp_name="pos",
            garfielddir=paste(garfielddir, "/pval", sep=""))
}

garfieldRun <- function(trait_name, garfielddir, annotations="1-1005",
                        penrichment=0.05) {
    message("Run Garfield analyses for trait: ", trait_name)
    garfieldRun <- system(paste("garfield", trait_name, garfielddir,
                                annotations, penrichment))
}

prepData <- function(input, name, link, filterTh=10, num_perm=100000,
                     category='Peaks') {
    input <- dplyr::filter(input,  NThresh >= filterTh,  Category == category)
    thresholdsP <- sort(unique(input$PThresh[which(!is.na(input$Pvalue))]))
    annotations <- unique(as.character(input$ID))
    tissues <- as.character(input$Tissue[match(annotations, input$ID)])

    enrichment <- matrix(NA, nrow=length(thresholdsP) + 1,
                         ncol=length(annotations))
    empPvalues <- matrix(NA, nrow=length(thresholdsP) + 1,
                         ncol=length(annotations))
    for (j in 1:length(annotations)) {
        for (i in 1:length(thresholdsP)) {
            enrichment[i,j] <- input$OR[which(input$ID == annotations[j] &
                                               input$PThresh == thresholdsP[i])]
            empPvalues[i,j] <- input$Pvalue[which(input$ID == annotations[j] &
                                                   input$PThresh == thresholdsP[i])]
        }
    }
    enrichment[length(thresholdsP) + 1, ] <- 1
    empPvalues[length(thresholdsP) + 1, ] <- 1
    empPvalues <- -log10(empPvalues)
    rownames(enrichment) <- c(thresholdsP, 1)
    rownames(empPvalues) <- c(thresholdsP, 1)
    colnames(enrichment) <- annotations
    colnames(empPvalues) <- annotations

    empPvalues_long <- reshape2::melt(empPvalues, value.name='empP')
    colnames(empPvalues_long)[1:2] <- c('Threshold', 'Index')

    enrichment_long <- reshape2::melt(enrichment, value.name='OR')
    colnames(enrichment_long)[1:2] <- c('Threshold', 'Index')
    enrichment_long$empP <- empPvalues_long$empP

    enrichment_long <- merge(enrichment_long, link, by='Index')
    enrichment_long$Tissue <- as.character(enrichment_long$Tissue)
    enrichment_long$Name <- name

    return(enrichment_long)
}

###########
## data ###
###########

option_list <- list(
    optparse$make_option(c("-d", "--directory"), action="store",
               dest="directory",
               type="character", help="Path to ukbb gwas directory
                [default: %default].", default=NULL),
    optparse$make_option(c("-gd", "--garfielddir"), action="store",
               dest="garfielddir",
               type="character", help="Path to directory with garfield data
                [default: %default].",
               default="/nfs/research1/birney/resources/human_reference/GARFIELD/garfield-data"),
    optparse$make_option(c("-p", "--penrichment"), action="store",
               dest="penrichment",
               type="character", help="Enrichment threshold
                [default: %default].", default=1e-3),
    optparse$make_option(c("-n", "--name"), action="store",
               dest="name",
               type="character", help="Name of analysis [default: %default].",
               default='summary'),
    optparse$make_option(c("--showProgress"), action="store_true",
               dest="verbose",
               default=FALSE, type="logical", help="If set, progress messages
               about analyses are printed to standard out ",
               "[default: %default]."),
    optparse$make_option(c("--debug"), action="store_true",
                dest="debug", default=FALSE, type="logical",
                help="If set, predefined arguments are used to test the script",
                "[default: %default].")
)

args <- optparse$parse_args(optparse$OptionParser(option_list=option_list))

if (args$debug) {
    args <- list()
    args$directory <- "~/data/ukbb/ukb-hrt/gwas"
    args$garfielddir <- paste("/nfs/research1/birney/resources/human_reference/",
                  "GARFIELD/garfield-data", sep="")
    args$penrichment <- 1e-3
    args$name <- 'summary'
    args$verbose <- TRUE
}
directory <- args$directory
garfielddir <- args$garfielddir
penrichment <- args$penrichment
name <- args$name

annotation_link <- data.table::fread(paste(garfielddir,
                                           '/annotation/link_file.txt', sep=""),
                                 data.table=FALSE, stringsAsFactors=FALSE)
peaks <- annotation_link$Index[annotation_link$Category == "Peaks"]
peaks_ranges <- "166-290,590-888"

gwas <- data.table::fread(paste(directory,
                                '/bgenie_", name, "_lm_st_genomewide.csv',
                                sep=""),
                          data.table=FALSE, stringsAsFactors=FALSE)
gwas$SNPID <- paste(gwas$chr, ":", gwas$pos, sep="")

index_logp <- which(grepl("log10p", colnames(gwas)))
traits <- gsub("-log10p", "", colnames(gwas)[index_logp])

###############
## analysis ###
###############

## prepare garfield data ####
perSlicePrep <- sapply(index_logp, prepAnalyses, bgenie=gwas,
                        annotations=peaks_ranges,
                        directory=directory)

## submit garfield jobs ####
perSummaryGarfield <- clustermq::Q(garfieldRun,
                                 trait_name=traits[c(2,4,6)],
                                 const=list(garfielddir=garfielddir,
                                            annotations=peaks_ranges,
                                            penrichment=penrichment),
                                 n_jobs=3, memory=50000)

## read garfield results ####
basalFD <- data.table::fread(paste(garfielddir, '/output/MeanBasalFD/',
                                 'garfield.test.MeanBasalFD.out', sep=""),
                           data.table=FALSE, stringsAsFactors=FALSE)

midFD <- data.table::fread(paste(garfielddir, '/output/MeanMidFD/',
                                 'garfield.test.MeanMidFD.out', sep=""),
                           data.table=FALSE, stringsAsFactors=FALSE)

apicalFD <- data.table::fread(paste(garfielddir, '/output/MeanApicalFD/',
                                 'garfield.test.MeanApicalFD.out', sep=""),
                           data.table=FALSE, stringsAsFactors=FALSE)


## format garfield results ####
mid <- prepData(input=midFD, link=annotation_link, name='Mid')
apical <- prepData(input=apicalFD, link=annotation_link, name='Apical')
basal <- prepData(input=basalFD, link=annotation_link, name='Basal')

combined <- rbind(basal, mid, apical)
combined$Name <- factor(combined$Name, levels=c("Basal", "Mid", "Apical"))


## select tissues of interest and represeentative colors
tissues_color <- c("tomato", "skyblue3", "yellow", "brown2", "lightgreen",
                   "lightgoldenrod3", "purple", "pink", "darkblue", "gray",
                   "darkgreen")
toi <- c("fetal_heart", "heart", 'fetal_muscle', 'muscle',
         "blood", "blood_vessel", 'epithelium')

toi_color <- c( '#de2d26', '#fb6a4a', '#756bb1', '#9e9ac8',
                '#e6f598' ,'#abdda4', '#66c2a5', '#666666')

all_color <- colorRampPalette(toi_color)(length(unique(combined$Tissue)))


section_color_all <- c('#016c59','#1c9099','#67a9cf')
section_color_selected <- c('#67a9cf','#1c9099','#016c59')

## depict region-wise annotation enrichments ####
# a) only tissues of interest
selected <- combined
selected$Tissue[!selected$Tissue %in% toi] <- 'other tissues'
selected$Tissue_labels <- as.numeric(factor(selected$Tissue,
                                            levels=c(toi, 'other tissues')))
selected$Tissue <- paste(selected$Tissue_labels,
                         gsub("_", " ", as.character(selected$Tissue)),
                         sep="-")
selected$Tissue <- factor(selected$Tissue,
                          levels=unique(selected$Tissue)[order(unique(selected$Tissue_labels))])
selected$Tissue_labels <- factor(selected$Tissue_labels,
                                 levels=sort(unique(selected$Tissue_labels)))


selected_red <- dplyr::filter(selected, Threshold >= 1e-6, empP > -log10(5e-3))

p_selected <- ggplot(selected_red, aes(x=Tissue_labels, y=OR, fill=Tissue))
p_selected <- p_selected +
    facet_grid(~Name, scales = "free_x", space="free_x") +
    geom_boxplot() +
    scale_fill_manual(values=toi_color, name="Tissue") +
    theme_bw() +
    theme(legend.position='bottom',
          strip.background=element_rect(fill='white'),
          strip.text = element_text(color='white'),
          axis.title.x=element_blank(),
          axis.ticks.x=element_blank()
    )
g_selected <- ggplot_gtable(ggplot_build(p_selected))
strip <- which(grepl('strip-t', g_selected$layout$name))
k <- 1
for (i in strip) {
    j <- which(grepl('rect', g_selected$grobs[[i]]$grobs[[1]]$childrenOrder))
    g_selected$grobs[[i]]$grobs[[1]]$children[[j]]$gp$fill <- section_color_selected[k]
    k <- k+1
}
grid.draw(g_selected)
ggsave(plot=g_selected,
       filename=paste(directory, '/annotation/Functional_enrichment_", name,
                      ".pdf', sep=""),
       height=3, width=6)


# b) all GARFIELD tissues
combined$Tissue_labels <- as.numeric(as.factor(combined$Tissue))
combined$Tissue <- paste(combined$Tissue_labels, combined$Tissue,
                         sep="-")
combined$Tissue <- factor(combined$Tissue,
                          levels=unique(combined$Tissue)[order(unique(combined$Tissue_labels))])
combined$Tissue_labels <- factor(combined$Tissue_labels,
                                 levels=sort(unique(combined$Tissue_labels)))

all_red <- dplyr::filter(combined, Threshold >= 1e-6, empP > -log10(5e-3))

p_all <- ggplot(all_red, aes(x=Tissue_labels, y=OR, fill=Tissue))
p_all <- p_all +
    facet_wrap(~Name, scales = "free_x", strip.position = 'top',
               ncol=1) +
    geom_boxplot() +
    scale_fill_manual(values=all_color, name="Tissue") +
    theme_bw() +
    theme(legend.position='bottom',
          strip.background=element_rect(fill='white'),
          strip.text = element_text(color='white'),
          axis.title.x=element_blank(),
          axis.ticks.x=element_blank()
    )


g_all <- ggplot_gtable(ggplot_build(p_all))
strip <- which(grepl('strip-t', g_all$layout$name))
k <- 1
for (i in strip) {
    j <- which(grepl('rect', g_all$grobs[[i]]$grobs[[1]]$childrenOrder))
    g_all$grobs[[i]]$grobs[[1]]$children[[j]]$gp$fill <- section_color_all[k]
    k <- k+1
}
grid.draw(g_all)
ggsave(plot=g_all,
       filename=paste(directory, '/annotation/Functional_enrichment_", name,
                      "_all.pdf', sep=""),
       height=8, width=9)
