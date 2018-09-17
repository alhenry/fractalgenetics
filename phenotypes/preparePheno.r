#################
## libraries ####
#################
options(import.path="/homes/hannah/GWAS/analysis/fd")
options(import.path="/homes/hannah/projects")
options(bitmapType = 'cairo', device = 'pdf')

modules::import_package('ggplot2', attach=TRUE)
modules::import_package('GGally', attach=TRUE)
optparse <- modules::import_package('optparse')
ukbtools <- modules::import_package('ukbtools')
related <- modules::import('GWAS/relatedness')
autofd <- modules::import('AutoFD_interpolation/fracDecimate')
stats <- modules::import('AutoFD_interpolation/summaryFD')
smooth <- modules::import('utils/smoothAddR2')


#################################
## parameters and input data ####
#################################
option_list <- list(
    make_option(c("-u", "--ukbdir"), action="store", dest="rawdir",
               type="character", help="Path to ukb directory with decrypted ukb
               key.html file [default: %default].", default=NULL),
    make_option(c("-o", "--outdir"), action="store", dest="rawdir",
               type="character", help="Path to output directory [default:
               %default].", default=NULL),
    make_option(c("-p", "--pheno"), action="store", dest="pheno",
               type="character", help="Path to fd phenotype file [default:
               %default].", default=NULL),
    make_option(c("-c", "--cov"), action="store", dest="cov",
               type="character", help="Path to LV volume covariate file
               [default: %default].", default=NULL),
    make_option(c("-i", "--interpolate"), action="store", dest="interpolate",
               type="integer", help="Number of slices to interpolate to
               [default: %default].", default=10),
    make_option(c("-s", "--samples"), action="store", dest="samples",
               type="character", help="Path to ukb genotype samples file
               [default: %default].", default=NULL),
    make_option(c("-r", "--relatedness"), action="store", dest="relatedness",
               type="character", help="Path to relatedness file generated by
               ukbgene rel [default: %default].", default=NULL),
    make_option(c("-e", "--europeans"), action="store", dest="europeans",
               type="character", help="Path to European samples file generated
               by ancestry.smk [default: %default].", default=NULL),
    make_option(c("-pcs", "--pcs"), action="store", dest="pcs",
                ptions(import.path="/homes/hannah/GWAS/analysis/fd")
               type="character", help="Path to pca output file generated by
               flashpca [default: %default].", default=NULL),
)

args <- optparse$parse_args(OptionParser(option_list=option_list))

if (FALSE) {
    args <- list()
    args$rawdir <- "~/data/ukbb/ukb-hrt/rawdata"
    args$outdir <- "~/data/ukbb/ukb-hrt/phenotypes"
    args$pheno <- "~/data/ukbb/ukb-hrt/rawdata/FD.csv"
    args$interpolate <- 10
    args$cov <- "~/data/ukbb/ukb-hrt/rawdata/VentricularVolumes.csv"
    args$samples <- "~/data/ukbb/ukb-hrt/rawdata/ukb18545_imp_chr1_v3_s487378.sample"
    args$relatedness <-"~/data/ukbb/ukb-hrt/rawdata/ukb18545_rel_s488346.dat"
    args$europeans <- "~/data/ukbb/ukb-hrt/ancestry/European_samples.csv"
    args$pcs <- "~/data/ukbb/ukb-hrt/ancestry/ukb_imp_genome_v3_maf0.1.pruned.European.pca"
}

## ukb phenotype files converted via ukb_tools:
# http://biobank.ctsu.ox.ac.uk/showcase/docs/UsingUKBData.pdf
# ukb_unpack ukb22219.enc key
# ukb_conv ukb22219.enc_ukb r
# ukb_conv ukb22219.enc_ukb docs
# get rosetta error, but according to
# https://biobank.ctsu.ox.ac.uk/crystal/exinfo.cgi?src=faq#rosetta, nothing to
# worry about

## ukb genotype files via https://biobank.ndph.ox.ac.uk/showcase/refer.cgi?id=664
# ukbgene rel ukb22219.enc
# ukbgene imp -c1 -m

################
## analysis ####
################

## FD measurements ####
dataFD <- data.table::fread(args$pheno, data.table=FALSE,
                            stringsAsFactors=FALSE, na.strings=c("NA", "NaN"))
rownames(dataFD) <- dataFD[, 1]
colnames(dataFD)[colnames(dataFD) == 'FD - Slice 1'] <- 'Slice 1'
dataFD <- dataFD[,grepl("Slice \\d{1,2}", colnames(dataFD))]
colnames(dataFD) <- gsub(" ", "", colnames(dataFD))

# Exclude individuals where less than 6 slices were measured
NaN_values <- c("Sparse myocardium", "Meagre blood pool","FD measure failed")
fd_notNA <- apply(dataFD, 1,  function(x) {
                length(which(!(is.na(x) | x %in% NaN_values))) > 5
                            })
dataFD <- dataFD[fd_notNA, ]

# manually look at non-numerics in FD slices
nn <- sort(unique(unlist(dataFD)), decreasing =TRUE)
dataFD <- as.data.frame(apply(dataFD, 2, function(x) {
    x[x %in% nn[2]] <- NA
    x[x %in% nn[c(1,3,4)]] <- NaN
    return(as.numeric(x))
}))

# plot distribution of nas
all_nas <- apply(fd_slices, 2, function(x) length(which(is.na(x))))
nans <- apply(fd_slices, 2, function(x) length(which(is.nan(x))))
nas <- all_nas - nans
complete <- nrow(fd_slices) - all_nas
data_na <- rbind(data.frame(Slice=1:ncol(fd_slices), samples=nas, type="NA"),
                 data.frame(Slice=1:ncol(fd_slices), samples=nans, type="NaN"),
                 data.frame(Slice=1:ncol(fd_slices), samples=complete,
                            type="Complete"))

p_na <- ggplot(data_na, aes(x=Slice, y=samples, color=type))
p_na <- p_na + geom_point(size=1) +
    facet_wrap(~type, nrow=3) +
    scale_color_brewer(type="qual", palette=6) +
    theme_bw()
ggsave(plot=p_na, file=paste(args$outdir, "/NAdist_FD.pdf", sep=""),
       height=4, width=4, units="in")

# interpolate FD slice measures
FDi <- autofd$fracDecimate(data=dataFD, interpNoSlices=args$interpolate,
                           id.col.name='rownames')

# summary fd measurements
summary_raw <- data.frame(t(apply(as.matrix(dataFD), 1, stats$summaryStatistics,
                       discard=FALSE)))
summary_raw <- reshape2::melt(summary_raw, id.var="SlicesUsed")

summary_interpolate <- data.frame(t(apply(as.matrix(FDi), 1,
                                          stats$summaryStatistics,
                       discard=FALSE)))
summary_interpolate <- reshape2::melt(summary_interpolate[,-1])

summary_all <- data.frame(type=summary_raw$variable, raw=summary_raw$value,
                          interpolate=summary_interpolate$value,
                          slices=summary_raw$SlicesUsed)

p_summary <- ggplot(summary_all, aes(x=raw, y=interpolate, color=type))
p_summary <- p_summary +
    smooth$stat_smooth_func(geom="text", method="lm", hjust=0, parse=TRUE,
                            xpos=0.9, ypos=1.4, vjust=0, color="black") +
    geom_smooth(method="lm", se=FALSE) +
    geom_point(size=1) +
    facet_wrap(~type, ncol=5) +
    scale_color_brewer(type="qual", palette=6) +
    theme_bw()
ggsave(plot=p_summary,
       file=paste(args$outdir, "/Raw_vs_interpolated.pdf", sep=""),
       height=3, width=15, units="in")



# LV volume measurements
lvv <- data.table::fread(args$cov, data.table=FALSE,
                            stringsAsFactors=FALSE, na.strings=c("NA", "NaN"))
rownames(lvv) <- lvv[, 1]

# ukbb phenotype dataset
ukbb <- ukb_df(fileset="ukb22219", path=args$rawdir)
saveRDS(ukbb, paste(args$rawdir, "/ukb22219.rds", sep=""))

ukbb_fd <- dplyr::filter(ukbb, eid %in% dataFD$Folder)
saveRDS(ukbb_fd, paste(args$rawdir, "/ukb22219_fd.rds", sep=""))

# ukbb genotype samples via ukbgene imp -c1 -m
samples <- data.table::fread(args$samples, data.table=FALSE, skip=2,
                             stringsAsFactors=FALSE,
                             col.names=c("ID_1", "ID_2", "missing", "sex"))

# ukbb relatedness file via ukbgene rel
relatedness <- data.table::fread(args$relatedness, data.table=FALSE,
                             stringsAsFactors=FALSE)
# European ancestry via ancestry.smk
europeans <- data.table::fread(args$europeans, data.table=FALSE,
                            stringsAsFactors=FALSE, col.names="ID")

# Principal components of European ancestry via ancestry.smk
pcs <- data.table::fread(args$pcs, data.table=FALSE, stringsAsFactors=FALSE)

## ukb covariates data ####
# grep columns with covariates sex, age, bmi and weight
sex <- which(grepl("genetic_sex_", colnames(ukbb_fd)))
age <- which(grepl("age_when_attended_assessment_centre",
    colnames(ukbb_fd)))
bmi <- which(grepl("bmi_", colnames(ukbb_fd)))
weight <- which(grepl("^weight_", colnames(ukbb_fd)))

# manually check which columns are relevant and most complete
sexNA <- is.na(ukbb_fd[,sex]) # length(which(sexNA)) -> 461
allSex <- ukbb_fd[!sexNA,] #  nrow(allSex) -> 19235

ageNA <- apply(ukbb_fd[!sexNA, age], 2, function(x)
    length(which(is.na(x)))) # 0,14298,1167
weightNA <- apply(ukbb_fd[!sexNA, weight], 2, function(x)
    length(which(is.na(x)))) # 28,14258,440
bmiNA <- apply(ukbb_fd[!sexNA, bmi] , 2, function(x)
    length(which(is.na(x)))) # 31,14259,479

relevant <- c(sex, age[which.min(ageNA)], weight[which.min(weightNA)],
    bmi[which.min(bmiNA)])

covs <- allSex[, relevant]
covs$genetic_sex_f22001_0_0 <- as.numeric(covs$genetic_sex_f22001_0_0)
index_noNA <- which(apply(covs, 1, function(x) !any(is.na(x))))
covs_noNA <- covs[index_noNA,]
covs_noNA <- as.data.frame(apply(covs_noNA, 2, as.numeric))
rownames(covs_noNA) <- allSex$eid[index_noNA]

covs_noNA$height_f21002_comp <-
    sqrt(covs_noNA$weight_f21002_0_0/covs_noNA$body_mass_index_bmi_f21001_0_0)

## FD measurements of interest for association mapping ####
fd_measured <- dataFD[,32:37]
colnames(fd_measured) <- c("Slices", "globalFD", "meanBasalFD", "meanApicalFD",
    "maxBasalFD", "maxApicalFD")




# summary FD measures
summaryFDi <- t(apply(FDi, 1, function(x) {
                       c(meanApicalFDi=mean(x[7:length(x)]),
                         maxApicalFDi=max(x[7:length(x)]),
                         meanMidFDi=mean(x[4:6]),
                         maxMidFDi=max(x[4:6]),
                         meanBasalFDi=mean(x[1:3]),
                         maxBasalFDi=max(x[1:3]))
       }))

# plot distribution of FD along heart
FDalongHeart <- reshape2::melt(FDi, value.name = "FD")
colnames(FDalongHeart)[1:2] <- c("ID", "Slice")

FDalongHeart$Slice <- as.factor(as.numeric(gsub("Slice_", "",
                                                FDalongHeart$Slice)))
FDalongHeart$Location <- "Apical section"
FDalongHeart$Location[as.numeric(FDalongHeart$Slice) <= 3] <- "Basal section"
FDalongHeart$Location[as.numeric(FDalongHeart$Slice) <= 6 &
                      as.numeric(FDalongHeart$Slice) > 3] <- "Mid section"
FDalongHeart$Location <- factor(FDalongHeart$Location,
                                levels=c("Basal section", "Mid section",
                                         "Apical section"))

p_fd <- ggplot(data=FDalongHeart)
p_fd <- p_fd + geom_boxplot(aes(x=Slice, y=FD, color=Location)) +
    scale_color_manual(values=c('#fdcc8a','#fc8d59','#e34a33')) +
    labs(x="Slice", y="FD") +
    theme_bw()

ggsave(plot=p_fd, file=paste(args$outdir, "/FDAlongHeart_slices",
                             args$interpolate, ".pdf", sep=""),
       height=4, width=4, units="in")

## Merge FD measures and covariates to order by samples ####
fd_all <- merge(fd_measured, FDi, by=0)
fd_all <- merge(fd_all, summaryFDi, by.x=1, by.y=0)
fd_all <- merge(fd_all, lvv, by=1)
fd_all <- merge(fd_all, covs_noNA, by.x=1, by.y=0)
fd_all$genetic_sex_f22001_0_0 <- as.factor(fd_all$genetic_sex_f22001_0_0)

fd_pheno_raw <- dplyr::select(fd_all, globalFD, meanBasalFD, meanApicalFD,
    maxBasalFD, maxApicalFD)

fd_pheno <- dplyr::select(fd_all, meanBasalFDi, meanMidFDi, meanApicalFDi,
                          maxBasalFDi, maxMidFDi, maxApicalFDi)

fd_cov <- dplyr::select(fd_all, LVEDV, genetic_sex_f22001_0_0,
    age_when_attended_assessment_centre_f21003_0_0, weight_f21002_0_0,
    body_mass_index_bmi_f21001_0_0, height_f21002_comp)

slices <- paste("Slice_", 1:args$interpolate, sep="")
fd_slices <- dplyr::select(fd_all, slices)

## Correlation summary measures raw phenotypes to interpolated phenotypes ####



## Test association of covariates ####
lm_fd_covs <- sapply(1:ncol(fd_pheno), function(x) {
    tmp <- lm(y ~ ., data=data.frame(y=fd_pheno[,x], fd_cov))
    summary(tmp)$coefficient[,4]
})
colnames(lm_fd_covs) <- colnames(fd_pheno)

write.table(fd_all, paste(args$outdir, "/FD_all_slices", args$interpolate,
                          ".csv", sep=""),
            sep=",", row.names=fd_all$Row.names, col.names=NA, quote=FALSE)
write.table(fd_pheno, paste(args$outdir, "/FD_phenotypes_slices",
                            args$interpolate, ".csv", sep=""),
            sep=",", row.names=fd_all$Row.names, col.names=NA, quote=FALSE)
write.table(fd_pheno_raw, paste(args$outdir, "/FD_phenotypes_raw.csv", sep=""),
            sep=",", row.names=fd_all$Row.names, col.names=NA, quote=FALSE)
write.table(fd_cov, paste(args$outdir, "/FD_covariates.csv", sep=""),
            sep=",", row.names=fd_all$Row.names, col.names=NA, quote=FALSE)


## Plot distribution of covariates ####
df <- dplyr::select(fd_all, Slices, maxBasalFDi, maxMidFDi, maxApicalFDi, LVEDV,
                    genetic_sex_f22001_0_0,
                    age_when_attended_assessment_centre_f21003_0_0,
                    weight_f21002_0_0,
                    body_mass_index_bmi_f21001_0_0, height_f21002_comp)
p <- ggpairs(df,
             upper = list(continuous = wrap("density", col="#b30000",
                                            size=0.1)),
             diag = list(continuous = wrap("densityDiag", size=0.4)),
             lower = list(continuous = wrap("smooth", alpha=0.5,size=0.1,
                                            pch=20),
                          combo = wrap("facethist")),
             columnLabels = c("Slices", "maxBasalFDi", "maxMidFDi",
                              "maxApicalFDi", "EDV~(ml)",
                              "Sex~(f/m)", "Age~(years)", "Height~(m)",
                              "Weight~(kg)", "BMI~(kg/m^2)"),
             labeller = 'label_parsed',
             axisLabels = "show") +
    theme_bw() +
    theme(panel.grid = element_blank(),
          axis.text = element_text(size=6),
          axis.text.x = element_text(angle=90),
          strip.text = element_text(size=8),
          strip.background = element_rect(fill="white", colour=NA))
p[6,5] <- p[6,5] + geom_histogram(binwidth=3)
ggsave(plot=p, file=paste(args$outdir, "/pairs_fdcovariates.png", sep=""),
       height=12, width=12, units="in")

df <- dplyr::select(fd_all, Slices, globalFD, maxBasalFD, maxApicalFD, LVEDV,
                    genetic_sex_f22001_0_0,
                    age_when_attended_assessment_centre_f21003_0_0,
                    weight_f21002_0_0,
                    body_mass_index_bmi_f21001_0_0, height_f21002_comp)
p <- ggpairs(df,
             upper = list(continuous = wrap("density", col="#b30000",
                                            size=0.1)),
             diag = list(continuous = wrap("densityDiag", size=0.4)),
             lower = list(continuous = wrap("smooth", alpha=0.5,size=0.1,
                                            pch=20),
                          combo = wrap("facethist")),
             columnLabels = c(colnames(fd_measured)[-c(3,4)], "EDV~(ml)",
                              "Sex~(f/m)", "Age~(years)", "Height~(m)",
                              "Weight~(kg)", "BMI~(kg/m^2)"),
             labeller = 'label_parsed',
             axisLabels = "show") +
    theme_bw() +
    theme(panel.grid = element_blank(),
          axis.text = element_text(size=6),
          axis.text.x = element_text(angle=90),
          strip.text = element_text(size=8),
          strip.background = element_rect(fill="white", colour=NA))
p[6,5] <- p[6,5] + geom_histogram(binwidth=3)
ggsave(plot=p, file=paste(args$outdir, "/pairs_fdcovariates_raw.png", sep=""),
       height=12, width=12, units="in")

## Filter phenotypes for ethnicity and relatedness ####
related_samples <- related$smartRelatednessFilter(fd_all$Row.names, relatedness)
related2filter <- c(related_samples$related2filter,
                    related_samples$related2decide$ID1)

fd_norelated <- fd_all[!fd_all$Row.names %in% related2filter,]
fd_europeans_norelated <- fd_norelated[fd_norelated$Row.names %in% europeans$ID,]

## Test association with all covs and principal components ####
fd_europeans_norelated <- merge(fd_europeans_norelated, pcs[,-1], by=1)
#index_pheno <- 3:7
#index_cov <- c(19,27:81)
index_pheno <- 17:22
index_cov <- c(24,32:86)

lm_fd_pcs <- sapply(index_pheno, function(x) {
    tmp <- lm(y ~ ., data=data.frame(y=fd_europeans_norelated[,x],
                                     fd_europeans_norelated[,index_cov]))
    summary(tmp)$coefficient[,4]
})
colnames(lm_fd_pcs) <- colnames(fd_europeans_norelated)[index_pheno]
rownames(lm_fd_pcs) <- c("intercept",
    colnames(fd_europeans_norelated)[index_cov])
sigAssociations <- which(apply(lm_fd_pcs, 1, function(x) any(x < 0.01)))

fd_europeans_norelated <- fd_europeans_norelated[,c(1,3:22,
    which(colnames(fd_europeans_norelated) %in% names(sigAssociations)))]

write.table(lm_fd_pcs[sigAssociations,],
            paste(args$outdir, "/FD_cov_associations.csv", sep=""), sep=",",
            row.names=TRUE, col.names=NA, quote=FALSE)


write.table(dplyr::select(fd_europeans_norelated, globalFD, meanBasalFD,
                          meanApicalFD, maxBasalFD, maxApicalFD),
            paste(args$outdir, "/FD_phenotypes_EUnorel_raw.csv", sep=""),
            sep=",",
            row.names=fd_europeans_norelated$Row.names, col.names=NA,
            quote=FALSE)
write.table(dplyr::select(fd_europeans_norelated, LVEDV, genetic_sex_f22001_0_0,
                          age_when_attended_assessment_centre_f21003_0_0,
                          weight_f21002_0_0, body_mass_index_bmi_f21001_0_0,
                          height_f21002_comp, PC1, PC2, PC7, PC14, PC24),
            paste(args$outdir, "/FD_covariates_EDV_EUnorel.csv", sep=""),
            sep=",", row.names=fd_europeans_norelated$Row.names, col.names=NA,
            quote=FALSE)
write.table(dplyr::select(fd_europeans_norelated, genetic_sex_f22001_0_0,
                          age_when_attended_assessment_centre_f21003_0_0,
                          weight_f21002_0_0, body_mass_index_bmi_f21001_0_0,
                          height_f21002_comp, PC1, PC2, PC7, PC14, PC24),
            paste(args$outdir, "/FD_covariates_EUnorel.csv", sep=""), sep=",",
            row.names=fd_europeans_norelated$Row.names, col.names=NA,
            quote=FALSE)
write.table(dplyr::select(fd_europeans_norelated, Slice_1, Slice_2,
            Slice_3, Slice_4, Slice_5, Slice_6, Slice_7, Slice_8, Slice_9,
            Slice_10),
            paste(args$outdir, "/FD_slices_EUnorel.csv", sep=""), sep=",",
            row.names=fd_europeans_norelated$Row.names, col.names=NA,
            quote=FALSE)

## Format phenotypes and covariates for bgenie ####
# Everything has to be matched to order in sample file; excluded and missing
# samples will have to be included in phenotypes and covariates and values set
# to -999

fd_bgenie <- merge(samples, fd_europeans_norelated, by=1, all.x=TRUE, sort=FALSE)
fd_bgenie <- fd_bgenie[match(samples$ID_1, fd_bgenie$ID_1),]
fd_bgenie$genetic_sex_f22001_0_0 <- as.numeric(fd_bgenie$genetic_sex_f22001_0_0)
fd_bgenie[is.na(fd_bgenie)] <- -999

write.table(dplyr::select(fd_bgenie, globalFD, meanBasalFD,
                          meanApicalFD, maxBasalFD, maxApicalFD),
            paste(args$outdir, "/FD_phenotypes_bgenie.txt", sep=""), sep=" ",
            row.names=FALSE, col.names=TRUE, quote=FALSE)
write.table(dplyr::select(fd_bgenie, Slice_1, Slice_2, Slice_3, Slice_4,
                          Slice_5, Slice_6, Slice_7, Slice_8, Slice_9,
                          Slice_10),
            paste(args$outdir, "/FD_slices_bgenie.txt", sep=""), sep=" ",
            row.names=FALSE, col.names=TRUE, quote=FALSE)
write.table(dplyr::select(fd_bgenie, LVEDV, genetic_sex_f22001_0_0,
                          age_when_attended_assessment_centre_f21003_0_0,
                          weight_f21002_0_0, body_mass_index_bmi_f21001_0_0,
                          height_f21002_comp, PC1, PC2, PC7, PC14, PC24),
            paste(args$outdir, "/FD_covariates_EDV_bgenie.txt", sep=""),
            sep=" ", row.names=FALSE, col.names=TRUE, quote=FALSE)
write.table(dplyr::select(fd_bgenie, genetic_sex_f22001_0_0,
                          age_when_attended_assessment_centre_f21003_0_0,
                          weight_f21002_0_0, body_mass_index_bmi_f21001_0_0,
                          height_f21002_comp, PC1, PC2, PC7, PC14, PC24),
            paste(args$outdir, "/FD_covariates_bgenie.txt", sep=""), sep=" ",
            row.names=FALSE, col.names=TRUE, quote=FALSE)

