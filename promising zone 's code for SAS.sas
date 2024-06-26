libname mylib'E:\Mylib\';
options nonotes nosource;
ods listing close;run;
ods html close;run;
filename mp_log'E:\Mylib\mp_log';
proc printto log= mp_log new;
*---------------------------------------------*
/*sub-macros*/
*---------------------------------------------*;
/*Generate random number under normal distribution.*/
%macro 
nor_gen(mu1,mu2,sigma1,sigma2,ss,r,seed,sim,ds);
%let seedend= %sysevalf(&seed + &sim - 1);
%let ratio=%eval(&r+1);
data &ds;
  do seed= &seed to &seedend;
    do i= 1 to &ss;
    call streaminit(&seed);
if mod(i,&ratio)=0 then do; x=rand('normal',&mu2,&sigma2);ARM = "C";end;
else do;x=rand('normal',&mu1,&sigma1);ARM = "T";end;
      output;
    end;
  end;
keep i seed ARM x;
proc sort;by seed;
run;
%mend;

/*When dtr=cont,perform analysis.*/
%macro
z(dat=,stage=);
proc means data=&dat(where=(ARM = "T" )) noprint;var x;by seed;
  output out= stat_t MEAN=mean_t STDERR=se_t;
proc means data=&dat(where=(ARM = "C" ))noprint;var x;by seed;
  output out= stat_c MEAN=mean_c STDERR=se_c;
data stat_&stage.;merge stat_t stat_c;by seed;run;
data stat_&stage.;set stat_&stage.;
  eff_&stage= mean_t - mean_c;
  se=sqrt(se_t**2+se_c**2);
  z_&stage= eff_&stage/se;
  keep seed eff_&stage z_&stage;
proc sort data=stat_&stage.;by seed;
run;
%mend;

*---------------------------------------------*
/*main-macro*/
*---------------------------------------------*;
%macro
mp(dtr=,mu1=,mu2=,sigma1=,sigma2=,max=,r=,f=,alpha_1s=,pow=,
          delta0=,sigma0=,eff_null=,seed=,sim=
          );

%let beta=%sysevalf(1-&pow);
%let z_alpha=%sysfunc(probit(%sysevalf(1-&alpha_1s)));
%let z_beta=%sysfunc(probit(%sysevalf(&pow)));

%let seedend= %sysevalf(&seed + &sim - 1);

%let ratio=%eval(&r+1);*r=n_t/n_c;

%let cp_ul=&pow.;

%let delta=%sysevalf(&mu2.-&mu1.);

/*Step1:Preparation*/
/*Step1-1:value transformation*/
/*caculate parameters of the GSD*/
ods trace on;
proc seqdesign altref=&delta0
               plots=boundary(hscale=samplesize)
               BOUNDARYSCALE= STDZ;
   OBrienFleming: design nstages=2
                  method=obf
                  ALT=UPPER
                  STOP=REJECT
                  ALPHA= &alpha_1s.
                  BETA= &beta.
                          ;
   samplesize model=twosamplemean(stddev=&sigma0.)
               ;
   ods output Boundary=GSD_Bnd;
   ods output SampleSize=GSD_SS;
run;
ods trace off;

data GSD;
      merge GSD_Bnd(keep= _Stage_ AltRef_U Bound_UA) GSD_SS(keep= _Stage_ N N1 N2 _Info_);
      by _Stage_ ;
      if _Stage_ = 1 then do;
      call symput('GSD_N1_c',N1);
      call symput('GSD_N1',N);
      call symput('Bound_UA_s1',Bound_UA);
      call symput('AltRef_U_s1',AltRef_U);
      end;
      if _Stage_ = 2 then do;
      call symput('GSD_N2_c',N1);
      call symput('GSD_N2',N);
      call symput('Bound_UA_s2',Bound_UA);
      call symput('AltRef_U_s2',AltRef_U);
      end;
      %put _USER_;
run;
/*Step1-2:sample size parameters*/

%if %lowcase(&dtr)=cont %then %do;
%let n0=%sysfunc(ceil(%sysevalf(2*((&z_alpha+&z_beta)**2)*(&sigma0**2)/((&delta0)**2))));
%put n0=&n0;
%end;

%let n1_c=%sysfunc(ceil(%sysevalf(&n0 * &f)));
%let n1_t=%sysfunc(ceil(%sysevalf(&n1_c * &r)));
%let n1=%eval(&n1_c + &n1_t);

%let n2=%eval(&ratio*&n0);
%let n2_c=%eval(&n0);
%let n2_t=%sysfunc(ceil(%sysevalf(&n2_c * &r)));

%let n2_inc=%eval(&n2 - &n1);
%let n2x= %sysevalf(&n2 * &max);*the maximum allow sample size;
%let n2x_inc=%eval(&n2x - &n1);

%let w1 = %sysfunc(sqrt(%sysevalf(&n1/&n2)));
%let w2 = %sysfunc(sqrt(%sysevalf((&n2 - &n1)/&n2)));

%let gsd_n1_t=%sysfunc(ceil(%sysevalf(&gsd_n1_c * &r)));
%let gsd_n2_t=%sysfunc(ceil(%sysevalf(&gsd_n2_c * &r)));

%put _USER_;

/*Step2-2: Simulate MP'PZ*/
/*Step2-2-1: set promissing zone*/
data cp;
  retain cp;do cp= 0.001 to 0.999 by 0.001;output;end;
run;
data result;
  set cp;
  p=probit(1-cp);
  z1=(&z_alpha-p*sqrt(1-&f))*sqrt(&f);
  r_delta1=z1/(&z_alpha+&z_beta)*&f;
  n2_inc_new=(&n1/z1**2)*((&z_alpha*sqrt(&n2)-z1*sqrt(&n1))/sqrt(&n2_inc)+&z_beta)**2;
  n2_new=&n1+(n2_inc_new);
  n2_new1=max(n2_new,&n2);
  n2_real=min(n2_new1,&n2x);
  n2_real_inc=n2_real-&n1;
  b= n2_real**(-0.5)*((sqrt(n2_real_inc/&n2_inc))*(&z_alpha*sqrt(&n2)-z1*sqrt(&n1))+z1*sqrt(&n1));
  output;
run;
data cc;
  set result(where=(b < &z_alpha. and cp < &pow.));
  proc sort data=cc;
  by b;
run;
data ee;
   set cc nobs=lastobs;
   if _N_ EQ lastobs then call symputx('cp_ll',cp);
run;

/*Step2-2-2: Data generation*/
%if %lowcase(&dtr)=cont %then %do;
%nor_gen(&mu1,&mu2,&sigma1,&sigma2,&n2x,&r,&seed,&sim,ss_all);
%end;

data ss_all;set ss_all;proc sort data=ss_all;by seed i;run;
data stage1;set ss_all;if i le &n1;proc sort;by seed;run;

data gsd_n1;set ss_all;if i le &gsd_n1;proc sort;by seed;run;
data gsd_n2;set ss_all;if i le &gsd_n2;proc sort;by seed;run;

/*Step2-2-3:Perform test for the i-th interim analysis */
/*IA for cont */
%if %lowcase(&dtr)=cont %then %do;*mp;

%z(dat=stage1,stage=n1);

data n1_stat1;
    set stat_n1;
      z1_obs=z_n1;
      n2_inc_new_obs=ceil((&n1/(z1_obs**2)) * (((&z_alpha*sqrt(&n2)-z1_obs*sqrt(&n1))/(&n2_inc**0.5))+&z_beta)**2);
    output;run;
%end;

%if %lowcase(&dtr)=cont %then %do;
data n1_stat1;
  set n1_stat1;
    stat_obs=(&z_alpha-z1_obs*sqrt(&f))/(sqrt(1-&f))-(z1_obs*(sqrt(1-&f)))/sqrt(&f);
    CP_obs=1-(probnorm(stat_obs));
    n2_new=n2_inc_new_obs+&n1;
    n2_limit=min(n2_new,&n2x);
    n2_star=max(n2_limit,&n2);
  output;
run;
%end;

*-----------------------------------------------------------------;
*IA;
*-----------------------------------------------------------------;
%if %lowcase(&dtr)=cont %then %do;
data n1_stat2;
set n1_stat1;
  retain zone;
  if CP_obs LT &CP_ll then do;zone="unfav"; n_mp=&n2;n_mpf=&n2;end;
  if CP_obs GE &CP_ll and CP_obs LT &cp_ul then do;zone="prom";n_mp=n2_star;n_mpf=&n2x;end;
  if CP_obs GE &cp_ul then do;zone="fav";n_mp=&n2;n_mpf=&n2;end;
  output;
run;

data n1_stat3;
  set n1_stat2;
  keep seed zone z_n1 cp_obs  n2_inc_new_obs n2_star n_mp n_mpf;
run;

data ss_all1;
merge n1_stat3 ss_all;
by seed;
run;

%end;

*-----------------------------------------------------------------;
*simulate the second stage;
*-----------------------------------------------------------------;
%if %lowcase(&dtr)=cont %then %do;
data mp;set ss_all1;if i <= n_mp;proc sort;by seed;run;
data stage1x;set mp;if &n1 < i;proc sort;by seed;run;
data stage2;set mp;if i <= &n2;proc sort;by seed;run;
data stage2x;set mp;proc sort;by seed;run;
data mpf;set ss_all1;if i <= n_mpf;proc sort;by seed;run;
data stage1xf;set mpf;if &n1 < i;proc sort;by seed;run;
%end;

/*Step2-2-5: Calculate the assessment indexes*/
%if %lowcase(&dtr)=cont %then %do;
%z(dat=stage2,stage=n2);*Fixed;
%z(dat=stage1x,stage=n1x);*chw;
%z(dat=stage1xf,stage=n1xf);*chwf;
%z(dat=mp,stage=n2x);*MP;
%z(dat=mpf,stage=n2xf);*MPF;
%z(dat=gsd_n1,stage=gsd_n1);*gsd_n1;
%z(dat=gsd_n2,stage=gsd_n2);*gsd_n2;
%end;

data z;
  merge n1_stat3 stat_n1 stat_n1x stat_n1xf stat_n2 stat_n2x stat_n2xf stat_gsd_n1 stat_gsd_n2;
  by seed;
run;

data z;*MP with ZCHW;
  set z;
  if zone="prom" then do; zchw=z_n1*&w1+z_n1x*&w2; zchwf=z_n1*&w1+z_n1xf*&w2;end;
  else if (zone= 'fav' or zone= 'unfav') then do; zchw=z_n1*&w1+z_n1x*&w2; zchwf=z_n1*&w1+z_n1xf*&w2;end;
run;

/*index*/
%if %lowcase(&dtr)=cont %then %do;
data end;*Judging & Verification;
  set z;
  if zchw GE &z_alpha then rej_chw=1;else rej_chw=0;
  if zchwf GE &z_alpha then rej_chwf=1;else rej_chwf=0;
  if z_n2 GE &z_alpha then rej_n2=1;else rej_n2=0;
  if z_n1 GE &z_alpha then rej_n1=1;else rej_n1=0;
  if z_n2x GE &z_alpha then rej_n2x=1;else rej_n2x=0;
  if z_n2xf GE &z_alpha then rej_n2xf=1;else rej_n2xf=0;
  if z_gsd_n1 GE &BOUND_UA_S1 then rej_gsd1=1;else rej_gsd1=0;
  if z_gsd_n2 GE &BOUND_UA_S2 then rej_gsd2=1;else rej_gsd2=0;
  if (rej_gsd1=1 or rej_gsd2=1) then rej_gsd=1;else rej_gsd=0;
  if rej_gsd1=1 then do;gsd_n=&gsd_n1;eff_gsd=eff_gsd_n1;end;
    else if rej_gsd1=0 then do;gsd_n=&gsd_n2;eff_gsd=eff_gsd_n2;end;
  output;
run;
%end;

/*final result*/

PROC MEANS DATA=end maxdec=4;/*table1��fig1*/
  VAR rej_n1 rej_n2 rej_gsd1 rej_gsd rej_n2x rej_n2xf rej_chw rej_chwf   
;
  output out=results1 
  mean= stage1 fixed gsd1 gsd mp mpf mp_chw mpf_chw
;
RUN;
data alpha;
  set results1;
  _delta0_=&delta0;
  _delta_=&delta;
  _sigam0_=&sigma0;
  _n1_=&n1;
  _n2_=&n2;
  _n2x_=&n2x;
  gsd_n1= &gsd_n1;
  gsd_n2= &gsd_n2;
  max= &max;
  cp_ll=&cp_ll.;
  cp_ul=&cp_ul.;
  BOUND_UA_S2= &BOUND_UA_S2;
  BOUND_UA_S1= &BOUND_UA_S1;
  power= &pow;
  f= &f;
run;
proc export data=alpha dbms=csv outfile="E:\Mylib\alpha_cont_&&dtr._&&max._&&alpha_1s._&&pow._&&delta0._&&sigma0._&&f._&&sim..csv";quit;

PROC MEANS DATA=end maxdec=2;/*table2��fig2��3��4*/
  VAR gsd_n n_mp n_mpf  
;
  output out=results2 
  mean= AveSS_gsd AveSS_mp AveSS_mpf
  std= StdSS_gsd StdSS_mp StdSS_mpf
  range= rangeSS_gsd rangeSS_mp rangeSS_mpf
  median= medianSS_gsd medianSS_mp medianSS_mpf
;
RUN;
data SS;
  set results2;
  _delta0_=&delta0;
  _delta_=&delta;
  _sigam0_=&sigma0;
  _n1_=&n1;
  _n2_=&n2;
  _n2x_=&n2x;
  gsd_n1= &gsd_n1;
  gsd_n2= &gsd_n2;
  max= &max;
  cp_ll=&cp_ll.;
  cp_ul=&cp_ul.;
  BOUND_UA_S2= &BOUND_UA_S2;
  BOUND_UA_S1= &BOUND_UA_S1;
  power= &pow;
  f= &f;
run;
proc export data=SS dbms=csv outfile="E:\Mylib\SS_cont_&&dtr._&&max._&&alpha_1s._&&pow._&&delta0._&&sigma0._&&f._&&sim..csv";quit;

PROC MEANS DATA=end maxdec=4;/*table5��fig5��6��7,class by zone*/
  CLASS zone;
  VAR rej_n1 rej_n2 rej_gsd1 rej_gsd rej_n2x rej_n2xf rej_chw rej_chwf
  eff_n2  eff_gsd eff_n2x  eff_n2xf   
  gsd_n n_mp n_mpf  
;
  output out=results3 
  mean= stage1 fixed gsd1 gsd mp mpf  mp_chw mpf_chw
  delta_fixed delta_gsd  delta_mp delta_mpf
  AveSS_gsd AveSS_mp AveSS_mpf
;
RUN;

data zone;
  set results3;
  _delta0_=&delta0;
  _delta_=&delta;
  _sigam0_=&sigma0;
  _n1_=&n1;
  _n2_=&n2;
  _n2x_=&n2x;
  gsd_n1= &gsd_n1;
  gsd_n2= &gsd_n2;
  max= &max;
  cp_ll=&cp_ll.;
  cp_ul=&cp_ul.;
  BOUND_UA_S2= &BOUND_UA_S2;
  BOUND_UA_S1= &BOUND_UA_S1;
  power= &pow;
  f= &f;
run;
proc export data=zone dbms=csv outfile="E:\Mylib\zone_cont_&&dtr._&&max._&&alpha_1s._&&pow._&&delta0._&&sigma0._&&f._&&sim..csv";quit;

proc export data=end dbms=csv  outfile="E:\Mylib\all_&&dtr._&&max._&&alpha_1s._&&pow._&&delta0._&&sigma0._&&f._&&sim..csv";quit;

%put _USER_;
/*Step2-3:clear cache*/
proc datasets lib=work kill memtype=data nolist;quit;
dm "clear log; clear output";quit;
run;
%mend;

*example;
%mp(dtr=cont,mu1=2,mu2=2,sigma1=1,sigma2=1,max=2,r=1,f=0.5,alpha_1s=0.025,pow=0.9,
  delta0=0.1,sigma0=1,eff_null=0,seed=20231024,sim=10000
);